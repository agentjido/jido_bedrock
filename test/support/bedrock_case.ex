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

  using do
    quote do
      @moduletag :tmp_dir

      alias Jido.Bedrock.Case.CheckpointFailureAgent
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
    :ok
  end

  setup context do
    CheckpointFailureAgent.reset()
    Jido.Bedrock.RealBedrockCase.setup_real_bedrock(context)
  end

  def unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  def unique_prefix do
    "test/#{System.unique_integer([:positive])}/"
  end
end
