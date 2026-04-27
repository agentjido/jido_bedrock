defmodule Jido.Bedrock.RealClusterPodTddTest do
  @moduledoc """
  Real Bedrock lifecycle specs for richer Jido runtime shapes.

  These cases exercise storage through `Jido.Agent.InstanceManager` with
  partitioned agents and through `Jido.Pod` topology orchestration.
  """

  use Jido.Bedrock.RealBedrockCase, async: false

  @moduletag :real_bedrock_tdd
  @moduletag :single_node
  @moduletag timeout: 60_000

  alias Jido.Agent.InstanceManager
  alias Jido.AgentServer
  alias Jido.Bedrock.Storage
  alias Jido.Pod
  alias Jido.Signal
  alias Jido.Thread
  alias Jido.Thread.Agent, as: ThreadAgent

  @pod_manager __MODULE__.PodManager
  @planner_manager __MODULE__.PlannerManager
  @executor_manager __MODULE__.ExecutorManager
  @reviewer_manager __MODULE__.ReviewerManager
  @batch_manager __MODULE__.BatchManager

  defmodule AdvanceMemoryAction do
    @moduledoc false
    use Jido.Action, name: "real_bedrock_advance_memory", schema: []

    @impl true
    def run(params, context) do
      amount = Map.get(params, :amount, 1)
      note = Map.get(params, :note, "advanced")
      phase = Map.get(params, :phase, :working)
      payload = Map.get(params, :payload, %{})

      memory = Map.get(context.state, :memory, %{})
      facts = Map.get(memory, :facts, [])

      fact = %{
        seq: length(facts) + 1,
        amount: amount,
        note: note,
        phase: phase,
        payload: payload
      }

      {:ok,
       %{
         counter: Map.get(context.state, :counter, 0) + amount,
         last_note: note,
         phase: phase,
         memory:
           memory
           |> Map.put(:facts, facts ++ [fact])
           |> Map.put(:last_payload, payload)
       }}
    end
  end

  defmodule AdvancedMemoryAgent do
    @moduledoc false
    use Jido.Agent,
      name: "jido_bedrock_real_advanced_memory_agent",
      strategy: {Jido.Agent.Strategy.Direct, thread?: true},
      schema: [
        counter: [type: :integer, default: 0],
        role: [type: :atom, default: :worker],
        phase: [type: :atom, default: :booting],
        last_note: [type: :any, default: nil],
        memory: [type: :map, default: %{}]
      ]

    @impl true
    def signal_routes(_ctx), do: [{"workflow.advance", AdvanceMemoryAction}]
  end

  defmodule AdvancedMemoryPod do
    @moduledoc false
    use Jido.Pod,
      name: "jido_bedrock_real_advanced_memory_pod",
      topology:
        Jido.Pod.Topology.new!(
          name: "advanced_memory_pod",
          nodes: %{
            planner: %{
              kind: :agent,
              module: Jido.Bedrock.RealClusterPodTddTest.AdvancedMemoryAgent,
              manager: Jido.Bedrock.RealClusterPodTddTest.PlannerManager,
              activation: :eager,
              initial_state: %{
                counter: 10,
                role: :planner,
                phase: :planning,
                memory: %{facts: [], lane: :planner}
              },
              meta: %{lane: :planner}
            },
            executor: %{
              kind: :agent,
              module: Jido.Bedrock.RealClusterPodTddTest.AdvancedMemoryAgent,
              manager: Jido.Bedrock.RealClusterPodTddTest.ExecutorManager,
              activation: :eager,
              initial_state: %{
                counter: 20,
                role: :executor,
                phase: :executing,
                memory: %{facts: [], lane: :executor}
              },
              meta: %{lane: :executor}
            },
            reviewer: %{
              kind: :agent,
              module: Jido.Bedrock.RealClusterPodTddTest.AdvancedMemoryAgent,
              manager: Jido.Bedrock.RealClusterPodTddTest.ReviewerManager,
              activation: :lazy,
              initial_state: %{
                counter: 30,
                role: :reviewer,
                phase: :reviewing,
                memory: %{facts: [], lane: :reviewer}
              },
              meta: %{lane: :reviewer}
            }
          },
          links: [
            {:depends_on, :executor, :planner},
            {:depends_on, :reviewer, :executor},
            {:owns, :planner, :executor},
            {:owns, :executor, :reviewer}
          ]
        ),
      schema: [
        workspace: [type: :map, default: %{}],
        phase: [type: :atom, default: :booting]
      ]
  end

  setup %{storage: storage} do
    jido_name = :"jido_bedrock_real_pod_#{System.unique_integer([:positive])}"
    start_supervised!({Jido, name: jido_name})

    start_instance_manager!(@pod_manager, AdvancedMemoryPod, storage, jido_name)
    start_instance_manager!(@planner_manager, AdvancedMemoryAgent, storage, jido_name)
    start_instance_manager!(@executor_manager, AdvancedMemoryAgent, storage, jido_name)
    start_instance_manager!(@reviewer_manager, AdvancedMemoryAgent, storage, jido_name)
    start_instance_manager!(@batch_manager, AdvancedMemoryAgent, storage, jido_name)

    on_exit(fn ->
      Enum.each(
        [@pod_manager, @planner_manager, @executor_manager, @reviewer_manager, @batch_manager],
        &:persistent_term.erase({InstanceManager, &1})
      )
    end)

    :ok
  end

  test "pod topology resumes eager and lazy memory agents after full shutdown", %{
    storage_opts: storage_opts
  } do
    pod_key = unique_id("memory-pod")

    assert {:ok, pod_pid1} =
             timed(fn ->
               Pod.get(
                 @pod_manager,
                 pod_key,
                 initial_state: %{
                   phase: :running,
                   workspace: %{tenant: "pod-tenant", goal: "durable-memory"}
                 }
               )
             end)

    assert {:ok, initial_nodes} = timed(fn -> Pod.nodes(pod_pid1) end)
    assert initial_nodes[:planner].status == :adopted
    assert initial_nodes[:executor].status == :adopted
    assert initial_nodes[:executor].owner == :planner
    assert initial_nodes[:reviewer].status == :stopped

    assert {:ok, planner_pid1} = timed(fn -> Pod.lookup_node(pod_pid1, :planner) end)
    assert {:ok, executor_pid1} = timed(fn -> Pod.lookup_node(pod_pid1, :executor) end)
    assert :error = timed(fn -> Pod.lookup_node(pod_pid1, :reviewer) end)
    assert {:ok, reviewer_pid1} = timed(fn -> Pod.ensure_node(pod_pid1, :reviewer) end)

    assert {:ok, planner_agent1} =
             call_advance(planner_pid1, 3, "planned before restart", :planning, %{turn: 1})

    assert {:ok, executor_agent1} =
             call_advance(executor_pid1, 5, "executed before restart", :executing, %{turn: 1})

    assert {:ok, reviewer_agent1} =
             call_advance(reviewer_pid1, 7, "reviewed before restart", :reviewing, %{turn: 1})

    assert_agent_memory(planner_agent1, :planner, 13, "planned before restart", 2)
    assert_agent_memory(executor_agent1, :executor, 25, "executed before restart", 2)
    assert_agent_memory(reviewer_agent1, :reviewer, 37, "reviewed before restart", 2)

    assert {:ok, active_nodes} = timed(fn -> Pod.nodes(pod_pid1) end)
    assert active_nodes[:reviewer].status == :adopted
    assert active_nodes[:reviewer].owner == :executor

    stop_child!(executor_pid1, reviewer_pid1, :reviewer)
    stop_child!(planner_pid1, executor_pid1, :executor)
    stop_child!(pod_pid1, planner_pid1, :planner)
    stop_instance!(@pod_manager, pod_key, pod_pid1)

    planner_checkpoint_key = {AdvancedMemoryAgent, {@planner_manager, active_nodes[:planner].key}}
    executor_checkpoint_key = {AdvancedMemoryAgent, {@executor_manager, active_nodes[:executor].key}}
    reviewer_checkpoint_key = {AdvancedMemoryAgent, {@reviewer_manager, active_nodes[:reviewer].key}}
    pod_checkpoint_key = {AdvancedMemoryPod, {@pod_manager, pod_key}}

    assert {:ok, persisted_pod} = timed(fn -> Storage.get_checkpoint(pod_checkpoint_key, storage_opts) end)
    assert persisted_pod.state.workspace.goal == "durable-memory"

    assert {:ok, persisted_planner} =
             timed(fn -> Storage.get_checkpoint(planner_checkpoint_key, storage_opts) end)

    assert {:ok, persisted_executor} =
             timed(fn -> Storage.get_checkpoint(executor_checkpoint_key, storage_opts) end)

    assert {:ok, persisted_reviewer} =
             timed(fn -> Storage.get_checkpoint(reviewer_checkpoint_key, storage_opts) end)

    assert persisted_planner.state.counter == 13
    assert persisted_executor.state.counter == 25
    assert persisted_reviewer.state.counter == 37

    restart_cluster!()

    assert {:ok, pod_pid2} = timed(fn -> Pod.get(@pod_manager, pod_key) end)
    refute pod_pid1 == pod_pid2

    assert {:ok, resumed_nodes} = timed(fn -> Pod.nodes(pod_pid2) end)
    assert resumed_nodes[:planner].status == :adopted
    assert resumed_nodes[:executor].status == :adopted
    assert resumed_nodes[:reviewer].status == :stopped

    assert {:ok, planner_pid2} = timed(fn -> Pod.lookup_node(pod_pid2, :planner) end)
    assert {:ok, executor_pid2} = timed(fn -> Pod.lookup_node(pod_pid2, :executor) end)
    assert {:ok, reviewer_pid2} = timed(fn -> Pod.ensure_node(pod_pid2, :reviewer) end)

    assert_resumed_agent(planner_pid2, :planner, 13, "planned before restart", 4)
    assert_resumed_agent(executor_pid2, :executor, 25, "executed before restart", 4)
    assert_resumed_agent(reviewer_pid2, :reviewer, 37, "reviewed before restart", 4)

    assert {:ok, resumed_planner} =
             call_advance(planner_pid2, 11, "planned after restart", :planning, %{turn: 2})

    assert {:ok, resumed_executor} =
             call_advance(executor_pid2, 13, "executed after restart", :executing, %{turn: 2})

    assert {:ok, resumed_reviewer} =
             call_advance(reviewer_pid2, 17, "reviewed after restart", :reviewing, %{turn: 2})

    assert_agent_memory(resumed_planner, :planner, 24, "planned after restart", 6)
    assert_agent_memory(resumed_executor, :executor, 38, "executed after restart", 6)
    assert_agent_memory(resumed_reviewer, :reviewer, 54, "reviewed after restart", 6)
  end

  test "partitioned agents survive concurrent traffic and restart", %{
    storage_opts: storage_opts
  } do
    work =
      for partition <- [:tenant_a, :tenant_b], slot <- 1..4 do
        %{
          key: "shared-memory-agent-#{slot}",
          partition: partition,
          seed: slot * 10,
          role: partition
        }
      end

    started =
      work
      |> Task.async_stream(
        fn item ->
          {:ok, pid} =
            InstanceManager.get(
              @batch_manager,
              item.key,
              partition: item.partition,
              initial_state: %{
                counter: item.seed,
                role: item.role,
                phase: :booted,
                memory: %{facts: [], partition: item.partition, slot: item.key}
              }
            )

          Map.put(item, :pid, pid)
        end,
        max_concurrency: 8,
        timeout: 10_000
      )
      |> collect_task_results()

    advanced =
      started
      |> Task.async_stream(&drive_agent_before_restart/1, max_concurrency: 8, timeout: 20_000)
      |> collect_task_results()

    Enum.each(advanced, fn item ->
      assert item.agent.state.counter == item.seed + 6
      assert item.agent.state.last_note == "before-restart-#{item.partition}-#{item.key}-3"
      assert %Thread{rev: 6} = ThreadAgent.get(item.agent)
    end)

    advanced
    |> Task.async_stream(&stop_partitioned_agent!/1, max_concurrency: 8, timeout: 20_000)
    |> collect_task_results()

    Enum.each(advanced, fn item ->
      checkpoint_key =
        {AdvancedMemoryAgent, Jido.partition_key({@batch_manager, item.key}, item.partition)}

      assert {:ok, persisted} = timed(fn -> Storage.get_checkpoint(checkpoint_key, storage_opts) end)
      assert persisted.state.counter == item.seed + 6
      assert persisted.thread.rev == 6
    end)

    restart_cluster!()

    resumed =
      advanced
      |> Task.async_stream(&resume_partitioned_agent!/1, max_concurrency: 8, timeout: 20_000)
      |> collect_task_results()

    Enum.each(resumed, fn item ->
      assert item.state.restored_from_storage == true
      assert item.state.agent.state.counter == item.seed + 6
      assert item.state.agent.state.role == item.role
      assert item.state.agent.state.memory.partition == item.partition
      assert %Thread{rev: 6} = ThreadAgent.get(item.state.agent)
    end)

    resumed
    |> Task.async_stream(&drive_agent_after_restart/1, max_concurrency: 8, timeout: 20_000)
    |> collect_task_results()
    |> Enum.each(fn item ->
      assert item.agent.state.counter == item.seed + 16
      assert item.agent.state.last_note == "after-restart-#{item.partition}-#{item.key}"
      assert %Thread{rev: 8} = ThreadAgent.get(item.agent)
    end)
  end

  defp start_instance_manager!(manager, agent, storage, jido_name) do
    start_supervised!(
      InstanceManager.child_spec(
        name: manager,
        agent: agent,
        idle_timeout: :infinity,
        storage: storage,
        registry_partitions: 4,
        agent_opts: [jido: jido_name]
      )
    )
  end

  defp call_advance(pid, amount, note, phase, payload) do
    timed(fn ->
      AgentServer.call(
        pid,
        Signal.new!(
          "workflow.advance",
          %{amount: amount, note: note, phase: phase, payload: payload},
          source: "/jido_bedrock/real-pod-test"
        )
      )
    end)
  end

  defp assert_agent_memory(agent, role, counter, last_note, thread_rev) do
    assert agent.state.role == role
    assert agent.state.counter == counter
    assert agent.state.last_note == last_note
    assert [last_fact | _] = Enum.reverse(agent.state.memory.facts)
    assert last_fact.note == last_note
    assert %Thread{rev: ^thread_rev} = ThreadAgent.get(agent)
  end

  defp assert_resumed_agent(pid, role, counter, last_note, thread_rev) do
    assert {:ok, state} = timed(fn -> AgentServer.state(pid) end)
    assert state.restored_from_storage == true
    assert_agent_memory(state.agent, role, counter, last_note, thread_rev)
  end

  defp stop_child!(parent_pid, child_pid, tag) do
    ref = Process.monitor(child_pid)
    assert :ok = timed(fn -> AgentServer.stop_child(parent_pid, tag, :shutdown) end)
    assert_receive {:DOWN, ^ref, :process, ^child_pid, _reason}, 5_000
    refute Process.alive?(child_pid)
  end

  defp stop_instance!(manager, key, pid, opts \\ []) do
    ref = Process.monitor(pid)
    assert :ok = timed(fn -> InstanceManager.stop(manager, key, opts) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    refute Process.alive?(pid)
  end

  defp drive_agent_before_restart(item) do
    agent =
      Enum.reduce(1..3, nil, fn step, _last_agent ->
        note = "before-restart-#{item.partition}-#{item.key}-#{step}"
        {:ok, agent} = call_advance(item.pid, step, note, :before_restart, %{step: step})
        agent
      end)

    Map.put(item, :agent, agent)
  end

  defp stop_partitioned_agent!(item) do
    stop_instance!(@batch_manager, item.key, item.pid, partition: item.partition)
    item
  end

  defp resume_partitioned_agent!(item) do
    {:ok, pid} = timed(fn -> InstanceManager.get(@batch_manager, item.key, partition: item.partition) end)
    {:ok, state} = timed(fn -> AgentServer.state(pid) end)

    item
    |> Map.put(:pid, pid)
    |> Map.put(:state, state)
  end

  defp drive_agent_after_restart(item) do
    note = "after-restart-#{item.partition}-#{item.key}"
    {:ok, agent} = call_advance(item.pid, 10, note, :after_restart, %{resumed: true})
    Map.put(item, :agent, agent)
  end

  defp collect_task_results(stream) do
    Enum.map(stream, fn
      {:ok, result} -> result
      {:exit, reason} -> flunk("task exited: #{inspect(reason)}")
    end)
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp timed(fun, timeout_ms \\ 5_000) do
    fun
    |> Task.async()
    |> Task.await(timeout_ms)
  end
end
