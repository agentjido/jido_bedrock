defmodule Jido.Bedrock.RealBedrockCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Bedrock.ObjectStorage
  alias Bedrock.ObjectStorage.LocalFilesystem
  alias Bedrock.Repo

  defmodule TestCluster do
    @moduledoc false
    use Bedrock.Cluster, otp_app: :bedrock, name: "jido_bedrock_real_cluster_tdd"
  end

  defmodule TestRepo do
    @moduledoc false
    use Repo, cluster: TestCluster
  end

  using do
    quote do
      @moduletag :tmp_dir

      import Jido.Bedrock.RealBedrockCase

      alias Jido.Bedrock.RealBedrockCase.TestCluster
      alias Jido.Bedrock.RealBedrockCase.TestRepo
    end
  end

  setup context do
    setup_real_bedrock(context)
  end

  def setup_real_bedrock(%{tmp_dir: tmp_dir}) do
    ensure_local_node_started!()

    original_config = Application.get_env(:bedrock, TestCluster)
    Application.put_env(:bedrock, TestCluster, node_config(tmp_dir))

    on_exit(fn ->
      stop_named_supervisor()

      if is_nil(original_config) do
        Application.delete_env(:bedrock, TestCluster)
      else
        Application.put_env(:bedrock, TestCluster, original_config)
      end
    end)

    start_cluster_supervisor()
    wait_for_layout!()

    storage_prefix = "integration/#{System.unique_integer([:positive])}/"
    storage_opts = [repo: TestRepo, prefix: storage_prefix]

    {:ok,
     tmp_dir: tmp_dir,
     storage_prefix: storage_prefix,
     storage_opts: storage_opts,
     storage: {Jido.Bedrock.Storage, storage_opts}}
  end

  def restart_cluster! do
    stop_named_supervisor()
    start_cluster_supervisor()
    wait_for_layout!(10_000)
    :ok
  end

  def stop_named_supervisor do
    case Process.whereis(TestCluster.otp_name(:supervisor)) do
      pid when is_pid(pid) ->
        try do
          Supervisor.stop(pid, :normal, 30_000)
        catch
          :exit, _reason -> :ok
        end

        wait_for_shutdown!()

      _ ->
        :ok
    end
  end

  def all_keys_for_prefix(prefix) do
    TestRepo.transact(fn ->
      TestRepo.get_range({prefix, Bedrock.Key.strinc(prefix)}) |> Enum.to_list()
    end)
  end

  def wait_for_layout!(timeout_ms \\ 20_000) do
    wait_until!(
      fn ->
        case {TestCluster.fetch_transaction_system_layout(), current_coordinator_epoch()} do
          {{:ok, tsl}, epoch} -> layout_ready?(tsl, epoch)
          _ -> false
        end
      end,
      timeout_ms
    )
  end

  defp start_cluster_supervisor do
    {:ok, _supervisor} =
      Supervisor.start_link(
        [TestCluster.child_spec([])],
        strategy: :one_for_one,
        name: TestCluster.otp_name(:supervisor)
      )

    :ok
  end

  defp wait_for_shutdown! do
    wait_until!(
      fn ->
        Enum.all?(
          [:supervisor, :link, :coordinator, :foreman],
          &is_nil(Process.whereis(TestCluster.otp_name(&1)))
        )
      end,
      30_000
    )
  end

  defp node_config(tmp_dir) do
    object_storage =
      ObjectStorage.backend(
        LocalFilesystem,
        root: Path.join([tmp_dir, "coordinator", "object_storage"])
      )

    [
      capabilities: [:coordination, :log, :materializer],
      path_to_descriptor: Path.join(tmp_dir, "bedrock.cluster"),
      object_storage: object_storage,
      trace: [:recovery, :storage],
      coordinator: [path: Path.join(tmp_dir, "coordinator"), persistent: true],
      worker: [path: Path.join(tmp_dir, "workers")],
      durability_mode: :relaxed,
      durability: [desired_replication_factor: 1, desired_logs: 1]
    ]
  end

  defp ensure_local_node_started! do
    if Node.self() == :nonode@nohost do
      node_name = :"jido_bedrock_real_#{System.unique_integer([:positive])}"

      case :net_kernel.start([node_name, :shortnames]) do
        {:ok, _pid} ->
          Node.set_cookie(:jido_bedrock_real)
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          flunk("failed to start local Erlang node: #{inspect(reason)}")
      end
    else
      :ok
    end
  end

  defp current_coordinator_epoch do
    case Process.whereis(TestCluster.otp_name(:coordinator)) do
      pid when is_pid(pid) ->
        case safe_sys_get_state(pid) do
          %{epoch: epoch} -> epoch
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp safe_sys_get_state(pid) do
    :sys.get_state(pid, 1_000)
  catch
    :exit, _reason -> :unavailable
  end

  defp layout_ready?(
         %{
           epoch: layout_epoch,
           logs: logs,
           services: services,
           proxies: proxies,
           resolvers: resolvers,
           shard_layout: shard_layout,
           metadata_materializer: metadata_materializer,
           shard_materializers: shard_materializers
         },
         coordinator_epoch
       ) do
    layout_epoch == coordinator_epoch and
      populated_map?(logs) and
      populated_map?(services) and
      populated_list?(proxies) and
      populated_list?(resolvers) and
      populated_map?(shard_layout) and
      is_pid(metadata_materializer) and
      populated_map?(shard_materializers) and
      shard_materializers_cover_layout?(shard_layout, shard_materializers)
  end

  defp layout_ready?(_, _), do: false

  defp shard_materializers_cover_layout?(shard_layout, shard_materializers) do
    shard_layout
    |> Map.values()
    |> Enum.map(fn {tag, _start_key} -> tag end)
    |> Enum.uniq()
    |> Enum.all?(&match?(pid when is_pid(pid), Map.get(shard_materializers, &1)))
  end

  defp populated_map?(value), do: is_map(value) and map_size(value) > 0
  defp populated_list?(value), do: is_list(value) and value != []

  defp wait_until!(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met before timeout")
      else
        Process.sleep(100)
        do_wait_until(fun, deadline)
      end
    end
  end
end
