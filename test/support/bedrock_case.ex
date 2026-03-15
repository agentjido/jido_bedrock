defmodule Jido.Bedrock.Case do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Jido.Bedrock.Storage

  defmodule FakeBedrockRepo do
    @moduledoc false
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{} end)
    end

    def transact(fun), do: transact(fun, [])

    def transact(fun, _opts) do
      fun.()
    catch
      {:rollback, reason} -> {:error, reason}
    end

    def rollback(reason), do: throw({:rollback, reason})

    def get(key), do: Agent.get(__MODULE__, &Map.get(&1, key))

    def put(key, value) do
      Agent.update(__MODULE__, &Map.put(&1, key, value))
      :ok
    end

    def clear(key) do
      Agent.update(__MODULE__, &Map.delete(&1, key))
      :ok
    end

    def get_range({start_key, end_key}) do
      Agent.get(__MODULE__, fn state ->
        state
        |> Enum.filter(fn {key, _value} -> key >= start_key and key < end_key end)
        |> Enum.sort_by(&elem(&1, 0))
      end)
    end

    def clear_range({start_key, end_key}) do
      Agent.update(__MODULE__, fn state ->
        state
        |> Enum.reject(fn {key, _value} -> key >= start_key and key < end_key end)
        |> Map.new()
      end)

      :ok
    end
  end

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

  using do
    quote do
      alias Jido.Bedrock.Case.CheckpointFailureAgent
      alias Jido.Bedrock.Case.FakeBedrockRepo
      alias Jido.Bedrock.Case.FlakyStorage
      alias Jido.Bedrock.Storage

      import Jido.Bedrock.Case
    end
  end

  setup_all do
    start_supervised!(CheckpointFailureAgent)
    start_supervised!(FakeBedrockRepo)
    {:ok, repo: FakeBedrockRepo}
  end

  setup do
    CheckpointFailureAgent.reset()
    FakeBedrockRepo.reset()

    prefix = unique_prefix()
    storage_opts = [repo: FakeBedrockRepo, prefix: prefix]

    {:ok, prefix: prefix, storage: {Storage, storage_opts}, storage_opts: storage_opts}
  end

  def unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  def unique_prefix do
    "test/#{System.unique_integer([:positive])}/"
  end
end
