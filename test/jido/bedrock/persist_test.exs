defmodule Jido.Bedrock.PersistTest do
  use Jido.Bedrock.Case, async: false

  alias Jido.Persist
  alias Jido.Bedrock.Error
  alias Jido.Thread
  alias Jido.Thread.Agent, as: ThreadAgent

  defmodule WorkflowAgent do
    use Jido.Agent,
      name: "bedrock_persist_workflow_agent",
      schema: [
        step: [type: :integer, default: 0],
        status: [type: :atom, default: :pending],
        data: [type: :map, default: %{}]
      ]

    @impl true
    def signal_routes(_ctx), do: []
  end

  test "hibernate/thaw round-trip restores state and thread", %{storage: storage, storage_opts: storage_opts} do
    agent_id = unique_id("roundtrip-agent")
    thread_id = unique_id("roundtrip-thread")

    agent =
      WorkflowAgent.new(id: agent_id)
      |> Map.update!(:state, &Map.merge(&1, %{step: 3, status: :running, data: %{topic: "durability"}}))
      |> ThreadAgent.put(
        Thread.new(id: thread_id)
        |> Thread.append(%{kind: :user_message, payload: %{content: "hello"}})
        |> Thread.append(%{kind: :assistant_message, payload: %{content: "world"}})
      )

    assert :ok = Persist.hibernate(storage, agent)
    assert {:ok, thawed} = Persist.thaw(storage, WorkflowAgent, agent_id)

    assert thawed.id == agent_id
    assert thawed.state.step == 3
    assert thawed.state.status == :running
    assert thawed.state.data == %{topic: "durability"}
    assert thawed.state[:__thread__].id == thread_id
    assert thawed.state[:__thread__].rev == 2
    assert Thread.entry_count(thawed.state[:__thread__]) == 2

    assert {:ok, stored_thread} = Storage.load_thread(thread_id, storage_opts)
    assert stored_thread.rev == 2
  end

  test "re-hibernate appends only new thread entries", %{storage: storage, storage_opts: storage_opts} do
    agent_id = unique_id("delta-agent")
    thread_id = unique_id("delta-thread")

    original =
      WorkflowAgent.new(id: agent_id)
      |> ThreadAgent.put(
        Thread.new(id: thread_id)
        |> Thread.append(%{kind: :note, payload: %{n: 1}})
        |> Thread.append(%{kind: :note, payload: %{n: 2}})
      )

    assert :ok = Persist.hibernate(storage, original)
    assert {:ok, thawed} = Persist.thaw(storage, WorkflowAgent, agent_id)

    updated =
      thawed
      |> ThreadAgent.append(%{kind: :note, payload: %{n: 3}})
      |> ThreadAgent.append(%{kind: :note, payload: %{n: 4}})

    assert :ok = Persist.hibernate(storage, updated)
    assert {:ok, stored_thread} = Storage.load_thread(thread_id, storage_opts)

    assert stored_thread.rev == 4
    assert Thread.entry_count(stored_thread) == 4

    assert stored_thread
           |> Thread.to_list()
           |> Enum.map(& &1.payload.n) == [1, 2, 3, 4]

    assert {:ok, checkpoint} = Storage.get_checkpoint({WorkflowAgent, agent_id}, storage_opts)
    assert checkpoint.thread == %{id: thread_id, rev: 4}
  end

  test "checkpoint write failure can be retried without duplicating the journal", %{
    storage: storage,
    storage_opts: storage_opts
  } do
    agent_id = unique_id("retry-agent")
    thread_id = unique_id("retry-thread")

    agent =
      WorkflowAgent.new(id: agent_id)
      |> ThreadAgent.put(
        Thread.new(id: thread_id)
        |> Thread.append(%{kind: :note, payload: %{text: "one"}})
        |> Thread.append(%{kind: :note, payload: %{text: "two"}})
      )

    CheckpointFailureAgent.arm_once()

    assert {:error, :forced_checkpoint_failure} =
             Persist.hibernate({FlakyStorage, storage_opts}, agent)

    assert {:ok, flushed_thread} = Storage.load_thread(thread_id, storage_opts)
    assert flushed_thread.rev == 2
    assert Thread.entry_count(flushed_thread) == 2
    assert :not_found = Storage.get_checkpoint({WorkflowAgent, agent_id}, storage_opts)

    assert :ok = Persist.hibernate(storage, agent)
    assert {:ok, retried_thread} = Storage.load_thread(thread_id, storage_opts)
    assert retried_thread.rev == 2
    assert Thread.entry_count(retried_thread) == 2

    assert {:ok, thawed} = Persist.thaw(storage, WorkflowAgent, agent_id)
    assert thawed.state[:__thread__].rev == 2
  end

  test "stale local copy is rejected after another copy advances the thread", %{
    storage: storage,
    storage_opts: storage_opts
  } do
    agent_id = unique_id("stale-agent")
    thread_id = unique_id("stale-thread")

    original =
      WorkflowAgent.new(id: agent_id)
      |> ThreadAgent.put(
        Thread.new(id: thread_id)
        |> Thread.append(%{kind: :note, payload: %{text: "seed"}})
      )

    assert :ok = Persist.hibernate(storage, original)
    assert {:ok, stale_copy} = Persist.thaw(storage, WorkflowAgent, agent_id)
    assert {:ok, fresh_copy} = Persist.thaw(storage, WorkflowAgent, agent_id)

    advanced =
      fresh_copy
      |> ThreadAgent.append(%{kind: :note, payload: %{text: "newer"}})

    assert :ok = Persist.hibernate(storage, advanced)
    assert {:error, :thread_rev_regression} = Persist.hibernate(storage, stale_copy)

    assert {:ok, stored_thread} = Storage.load_thread(thread_id, storage_opts)
    assert stored_thread.rev == 2
    assert Thread.entry_count(stored_thread) == 2
  end

  test "thaw fails deterministically when a checkpoint points at a missing thread", %{
    storage: storage,
    storage_opts: storage_opts
  } do
    agent_id = unique_id("missing-thread-agent")

    checkpoint = %{
      version: 1,
      agent_module: WorkflowAgent,
      id: agent_id,
      state: %{step: 0, status: :pending, data: %{}},
      thread: %{id: unique_id("missing-thread"), rev: 1}
    }

    assert :ok = Storage.put_checkpoint({WorkflowAgent, agent_id}, checkpoint, storage_opts)
    assert {:error, :missing_thread} = Persist.thaw(storage, WorkflowAgent, agent_id)
  end

  test "thaw fails when the stored thread revision does not match the checkpoint pointer", %{
    storage: storage,
    storage_opts: storage_opts
  } do
    agent_id = unique_id("mismatch-agent")
    thread_id = unique_id("mismatch-thread")

    assert {:ok, _thread} =
             Storage.append_thread(
               thread_id,
               [
                 %{kind: :note, payload: %{text: "one"}},
                 %{kind: :note, payload: %{text: "two"}}
               ],
               storage_opts
             )

    checkpoint = %{
      version: 1,
      agent_module: WorkflowAgent,
      id: agent_id,
      state: %{step: 0, status: :pending, data: %{}},
      thread: %{id: thread_id, rev: 10}
    }

    assert :ok = Storage.put_checkpoint({WorkflowAgent, agent_id}, checkpoint, storage_opts)
    assert {:error, :thread_mismatch} = Persist.thaw(storage, WorkflowAgent, agent_id)
  end

  test "storage failures propagate Splode errors through thaw", %{storage_opts: storage_opts} do
    bad_storage = {Storage, Keyword.put(storage_opts, :prefix, "invalid-prefix")}

    assert {:error, %Error.ConfigError{} = error} = Persist.thaw(bad_storage, WorkflowAgent, unique_id("bad-storage"))
    assert error.key == :prefix
  end
end
