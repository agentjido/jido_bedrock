defmodule Jido.Bedrock.RealClusterSingleNodeTddTest do
  @moduledoc """
  Single-node real Bedrock lifecycle specs.

  These are intentionally excluded from the default `mix test` alias and are
  meant to drive the next round of Bedrock/Jido.Bedrock integration work.
  """

  use Jido.Bedrock.RealBedrockCase, async: false

  @moduletag :real_bedrock_tdd
  @moduletag :single_node
  @moduletag timeout: 15_000

  alias Jido.Bedrock.Storage
  alias Jido.Persist
  alias Jido.Thread
  alias Jido.Thread.Agent, as: ThreadAgent

  defmodule WorkflowAgent do
    use Jido.Agent,
      name: "jido_bedrock_real_cluster_tdd_workflow_agent",
      schema: [
        step: [type: :integer, default: 0],
        status: [type: :atom, default: :pending],
        data: [type: :map, default: %{}]
      ]

    @impl true
    def signal_routes(_ctx), do: []
  end

  test "checkpoint and thread survive a single-node restart", %{storage: storage} do
    agent_id = unique_id("restart-agent")
    thread_id = unique_id("restart-thread")

    agent =
      build_agent(agent_id, thread_id, [
        %{kind: :user_message, payload: %{content: "hello"}},
        %{kind: :assistant_message, payload: %{content: "world"}}
      ])

    assert :ok = timed(fn -> Persist.hibernate(storage, agent) end)
    restart_cluster!()

    assert {:ok, thawed} = timed(fn -> Persist.thaw(storage, WorkflowAgent, agent_id) end)
    assert thawed.state.step == 2
    assert thawed.state.status == :running
    assert thawed.state.data == %{topic: "single-node"}
    assert thawed.state.__thread__.id == thread_id
    assert thawed.state.__thread__.rev == 2
    assert Thread.entry_count(thawed.state.__thread__) == 2
  end

  test "appends after restart stay ordered and are not duplicated across a second restart", %{
    storage: storage,
    storage_opts: storage_opts
  } do
    agent_id = unique_id("append-agent")
    thread_id = unique_id("append-thread")

    original =
      build_agent(agent_id, thread_id, [
        %{kind: :note, payload: %{n: 1}},
        %{kind: :note, payload: %{n: 2}}
      ])

    assert :ok = timed(fn -> Persist.hibernate(storage, original) end)
    restart_cluster!()

    assert {:ok, thawed_once} = timed(fn -> Persist.thaw(storage, WorkflowAgent, agent_id) end)

    updated =
      thawed_once
      |> ThreadAgent.append(%{kind: :note, payload: %{n: 3}})
      |> ThreadAgent.append(%{kind: :note, payload: %{n: 4}})

    assert :ok = timed(fn -> Persist.hibernate(storage, updated) end)
    restart_cluster!()

    assert {:ok, thawed_twice} = timed(fn -> Persist.thaw(storage, WorkflowAgent, agent_id) end)
    assert thawed_twice.state.__thread__.rev == 4

    assert thawed_twice.state.__thread__
           |> Thread.to_list()
           |> Enum.map(& &1.payload.n) == [1, 2, 3, 4]

    assert {:ok, stored_thread} = timed(fn -> Storage.load_thread(thread_id, storage_opts) end)
    assert stored_thread.rev == 4
    assert Thread.entry_count(stored_thread) == 4
  end

  test "stale copy is rejected after another copy advances and persists through restart", %{
    storage: storage
  } do
    agent_id = unique_id("stale-agent")
    thread_id = unique_id("stale-thread")

    original =
      build_agent(agent_id, thread_id, [
        %{kind: :note, payload: %{text: "seed"}}
      ])

    assert :ok = timed(fn -> Persist.hibernate(storage, original) end)
    restart_cluster!()

    assert {:ok, stale_copy} = timed(fn -> Persist.thaw(storage, WorkflowAgent, agent_id) end)
    assert {:ok, fresh_copy} = timed(fn -> Persist.thaw(storage, WorkflowAgent, agent_id) end)

    advanced =
      fresh_copy
      |> ThreadAgent.append(%{kind: :note, payload: %{text: "newer"}})

    assert :ok = timed(fn -> Persist.hibernate(storage, advanced) end)
    restart_cluster!()

    assert {:error, :thread_rev_regression} = timed(fn -> Persist.hibernate(storage, stale_copy) end)
    assert {:ok, latest} = timed(fn -> Persist.thaw(storage, WorkflowAgent, agent_id) end)
    assert latest.state.__thread__.rev == 2
  end

  test "deleted agent state stays deleted after restart", %{
    storage: storage,
    storage_opts: storage_opts
  } do
    agent_id = unique_id("delete-agent")
    thread_id = unique_id("delete-thread")

    agent =
      build_agent(agent_id, thread_id, [
        %{kind: :note, payload: %{text: "erase me"}}
      ])

    assert :ok = timed(fn -> Persist.hibernate(storage, agent) end)
    assert :ok = timed(fn -> Storage.delete_thread(thread_id, storage_opts) end)
    assert :ok = timed(fn -> Storage.delete_checkpoint({WorkflowAgent, agent_id}, storage_opts) end)
    restart_cluster!()

    assert :not_found = timed(fn -> Storage.get_checkpoint({WorkflowAgent, agent_id}, storage_opts) end)
    assert :not_found = timed(fn -> Storage.load_thread(thread_id, storage_opts) end)
    assert {:error, :not_found} = timed(fn -> Persist.thaw(storage, WorkflowAgent, agent_id) end)
  end

  test "storage prefixes stay isolated across restart", %{storage_opts: base_opts} do
    left_opts = Keyword.put(base_opts, :prefix, base_opts[:prefix] <> "left/")
    right_opts = Keyword.put(base_opts, :prefix, base_opts[:prefix] <> "right/")

    left_storage = {Jido.Bedrock.Storage, left_opts}
    right_storage = {Jido.Bedrock.Storage, right_opts}

    left_agent_id = unique_id("left-agent")
    right_agent_id = unique_id("right-agent")
    shared_thread_id = unique_id("shared-thread")

    assert :ok =
             timed(fn ->
               Persist.hibernate(
                 left_storage,
                 build_agent(left_agent_id, shared_thread_id, [%{kind: :note, payload: %{side: :left}}])
               )
             end)

    assert :ok =
             timed(fn ->
               Persist.hibernate(
                 right_storage,
                 build_agent(right_agent_id, shared_thread_id, [%{kind: :note, payload: %{side: :right}}])
               )
             end)

    restart_cluster!()

    assert {:ok, left_agent} = timed(fn -> Persist.thaw(left_storage, WorkflowAgent, left_agent_id) end)
    assert {:ok, right_agent} = timed(fn -> Persist.thaw(right_storage, WorkflowAgent, right_agent_id) end)
    assert left_agent.state.__thread__.entries |> List.first() |> then(& &1.payload.side) == :left
    assert right_agent.state.__thread__.entries |> List.first() |> then(& &1.payload.side) == :right
    assert {:error, :not_found} = timed(fn -> Persist.thaw(left_storage, WorkflowAgent, right_agent_id) end)
    assert {:error, :not_found} = timed(fn -> Persist.thaw(right_storage, WorkflowAgent, left_agent_id) end)
  end

  test "large threads survive restart with all entries intact", %{storage: storage} do
    agent_id = unique_id("large-agent")
    thread_id = unique_id("large-thread")

    entries =
      for n <- 1..128 do
        %{kind: :note, payload: %{n: n}}
      end

    assert :ok = timed(fn -> Persist.hibernate(storage, build_agent(agent_id, thread_id, entries)) end)
    restart_cluster!()

    assert {:ok, thawed} = timed(fn -> Persist.thaw(storage, WorkflowAgent, agent_id) end)
    assert thawed.state.__thread__.rev == 128

    assert thawed.state.__thread__
           |> Thread.to_list()
           |> Enum.map(& &1.payload.n) == Enum.to_list(1..128)
  end

  defp build_agent(agent_id, thread_id, entries) do
    thread =
      Enum.reduce(entries, Thread.new(id: thread_id), fn entry, acc ->
        Thread.append(acc, entry)
      end)

    WorkflowAgent.new(id: agent_id)
    |> Map.update!(:state, &Map.merge(&1, %{step: length(entries), status: :running, data: %{topic: "single-node"}}))
    |> ThreadAgent.put(thread)
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp timed(fun, timeout_ms \\ 5_000) do
    fun
    |> Task.async()
    |> Task.await(timeout_ms)
  end
end
