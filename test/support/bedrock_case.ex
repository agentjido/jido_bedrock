defmodule Jido.Bedrock.Case do
  @moduledoc false
  use ExUnit.CaseTemplate

  defmodule CheckpointFailureAgent do
    @moduledoc false
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> false end, name: __MODULE__)
    end

    def arm_once do
      Agent.update(__MODULE__, fn _ -> true end)
    end

    def consume_failure? do
      Agent.get_and_update(__MODULE__, fn armed? -> {armed?, false} end)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> false end)
    end
  end

  defmodule FlakyStorage do
    @moduledoc false
    @behaviour Jido.Storage

    alias Jido.Bedrock.Case.CheckpointFailureAgent
    alias Jido.Bedrock.Storage

    @impl true
    def get_checkpoint(key, opts), do: Storage.get_checkpoint(key, opts)

    @impl true
    def put_checkpoint(key, data, opts) do
      if CheckpointFailureAgent.consume_failure?() do
        {:error, :forced_checkpoint_failure}
      else
        Storage.put_checkpoint(key, data, opts)
      end
    end

    @impl true
    def delete_checkpoint(key, opts), do: Storage.delete_checkpoint(key, opts)

    @impl true
    def load_thread(thread_id, opts), do: Storage.load_thread(thread_id, opts)

    @impl true
    def append_thread(thread_id, entries, opts), do: Storage.append_thread(thread_id, entries, opts)

    @impl true
    def delete_thread(thread_id, opts), do: Storage.delete_thread(thread_id, opts)
  end

  defmodule FakeRepo do
    @moduledoc false
    use Agent

    @tx_key {__MODULE__, :tx_state}

    def start_link(_opts) do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{} end)
    end

    def transact(fun, _opts \\ []) do
      case Process.get(@tx_key) do
        nil ->
          Agent.get_and_update(__MODULE__, fn initial ->
            Process.put(@tx_key, initial)

            try do
              result = run_fun(fun)
              tx_state = Process.get(@tx_key)
              {result, tx_state}
            catch
              {__MODULE__, :rollback, reason} -> {{:error, reason}, initial}
            after
              Process.delete(@tx_key)
            end
          end)

        _tx_state ->
          do_transact(fun)
      end
    end

    defp do_transact(fun) do
      case Process.get(@tx_key) do
        nil ->
          initial = Agent.get(__MODULE__, & &1)
          Process.put(@tx_key, initial)

          try do
            result = run_fun(fun)
            tx_state = Process.get(@tx_key)
            Agent.update(__MODULE__, fn _ -> tx_state end)
            result
          catch
            {__MODULE__, :rollback, reason} -> {:error, reason}
          after
            Process.delete(@tx_key)
          end

        _tx_state ->
          try do
            run_fun(fun)
          catch
            {__MODULE__, :rollback, reason} -> {:error, reason}
          end
      end
    end

    def rollback(reason), do: throw({__MODULE__, :rollback, reason})

    def get(key), do: current_state() |> Map.get(key)

    def put(key, value) do
      update_state(&Map.put(&1, key, value))
      :ok
    end

    def clear(key) do
      update_state(&Map.delete(&1, key))
      :ok
    end

    def get_range({start_key, end_key}) do
      current_state()
      |> Enum.filter(fn {key, _value} -> key >= start_key and key < end_key end)
      |> Enum.sort_by(&elem(&1, 0))
    end

    def clear_range({start_key, end_key}) do
      update_state(fn state ->
        state
        |> Enum.reject(fn {key, _value} -> key >= start_key and key < end_key end)
        |> Map.new()
      end)

      :ok
    end

    defp run_fun(fun) do
      case Function.info(fun, :arity) do
        {:arity, 1} -> fun.(__MODULE__)
        {:arity, 0} -> fun.()
      end
    end

    defp current_state do
      Process.get(@tx_key) || Agent.get(__MODULE__, & &1)
    end

    defp update_state(fun) do
      case Process.get(@tx_key) do
        nil ->
          Agent.update(__MODULE__, fun)

        tx_state ->
          Process.put(@tx_key, fun.(tx_state))
      end
    end
  end

  using do
    quote do
      @moduletag :tmp_dir

      alias Jido.Bedrock.Case.CheckpointFailureAgent
      alias Jido.Bedrock.Case.FakeRepo
      alias Jido.Bedrock.Case.FlakyStorage
      alias Jido.Bedrock.RealBedrockCase.TestCluster
      alias Jido.Bedrock.RealBedrockCase.TestRepo
      alias Jido.Bedrock.Storage

      import Jido.Bedrock.Case
      import Jido.Bedrock.RealBedrockCase
    end
  end

  setup_all do
    start_supervised!(CheckpointFailureAgent)
    start_supervised!(FakeRepo)
    :ok
  end

  setup _context do
    CheckpointFailureAgent.reset()
    FakeRepo.reset()

    storage_prefix = unique_prefix()
    storage_opts = [repo: FakeRepo, prefix: storage_prefix]

    {:ok, storage_prefix: storage_prefix, storage_opts: storage_opts, storage: {Jido.Bedrock.Storage, storage_opts}}
  end

  def unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  def unique_prefix do
    "test/#{System.unique_integer([:positive])}/"
  end
end
