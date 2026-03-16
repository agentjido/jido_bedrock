defmodule Jido.Bedrock.InstanceManagerResumeTest do
  use Jido.Bedrock.Case, async: false

  alias Jido.Agent.InstanceManager
  alias Jido.AgentServer
  alias Jido.Signal
  alias Jido.Bedrock.Storage

  defmodule AdvanceWorkflowAction do
    @moduledoc false
    use Jido.Action, name: "workflow_advance", schema: []

    @impl true
    def run(params, context) do
      amount = Map.get(params, :amount, 1)
      note = Map.get(params, :note, "advanced")
      counter = Map.get(context.state, :counter, 0) + amount

      {:ok, %{counter: counter, last_note: note}}
    end
  end

  defmodule DurableWorkflowAgent do
    @moduledoc false
    use Jido.Agent,
      name: "durable_workflow_agent",
      schema: [
        counter: [type: :integer, default: 0],
        last_note: [type: :any, default: nil]
      ]

    @impl true
    def signal_routes(_ctx) do
      [{"workflow.advance", AdvanceWorkflowAction}]
    end
  end

  setup %{storage: storage} do
    jido_name = :"jido_bedrock_resume_#{System.unique_integer([:positive])}"
    manager_name = :"jido_bedrock_resume_manager_#{System.unique_integer([:positive])}"

    start_supervised!({Jido, name: jido_name})

    start_supervised!(
      InstanceManager.child_spec(
        name: manager_name,
        agent: DurableWorkflowAgent,
        idle_timeout: :infinity,
        storage: storage,
        agent_opts: [jido: jido_name]
      )
    )

    on_exit(fn -> :persistent_term.erase({InstanceManager, manager_name}) end)

    {:ok, manager: manager_name}
  end

  test "agent resumes as a new process after a full shutdown", %{
    manager: manager,
    storage_opts: storage_opts
  } do
    agent_key = unique_id("resume-agent")

    {:ok, pid1} =
      InstanceManager.get(manager, agent_key, initial_state: %{counter: 3, last_note: "boot"})

    signal =
      Signal.new!(
        "workflow.advance",
        %{amount: 2, note: "persisted before shutdown"},
        source: "/jido_bedrock/test"
      )

    assert {:ok, updated_agent} = AgentServer.call(pid1, signal)
    assert updated_agent.state.counter == 5
    assert updated_agent.state.last_note == "persisted before shutdown"

    checkpoint_key = {DurableWorkflowAgent, {manager, agent_key}}
    assert :not_found = Storage.get_checkpoint(checkpoint_key, storage_opts)

    pid1_ref = Process.monitor(pid1)
    assert :ok = InstanceManager.stop(manager, agent_key)
    assert_receive {:DOWN, ^pid1_ref, :process, ^pid1, _reason}, 5_000
    refute Process.alive?(pid1)

    assert {:ok, persisted_checkpoint} = Storage.get_checkpoint(checkpoint_key, storage_opts)
    assert persisted_checkpoint.state.counter == 5
    assert persisted_checkpoint.thread == nil

    assert {:ok, pid2} = InstanceManager.get(manager, agent_key)
    refute pid1 == pid2
    assert Process.alive?(pid2)

    assert {:ok, resumed_state} = AgentServer.state(pid2)
    assert resumed_state.restored_from_storage == true
    assert resumed_state.agent.state.counter == 5
    assert resumed_state.agent.state.last_note == "persisted before shutdown"

    resumed_signal =
      Signal.new!(
        "workflow.advance",
        %{amount: 4, note: "resumed after shutdown"},
        source: "/jido_bedrock/test"
      )

    assert {:ok, resumed_agent} = AgentServer.call(pid2, resumed_signal)
    assert resumed_agent.state.counter == 9
    assert resumed_agent.state.last_note == "resumed after shutdown"
  end
end
