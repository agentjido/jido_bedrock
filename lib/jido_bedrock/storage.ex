defmodule Jido.Bedrock.Storage do
  @moduledoc """
  Bedrock-backed `Jido.Storage` adapter.

  Required options:

  - `:repo` - loaded module implementing the `Bedrock.Repo` API

  Optional options:

  - `:prefix` - non-empty key prefix ending in `/` (default: `"jido_bedrock/"`)
  - `:expected_rev` - non-negative expected thread revision for appends
  - `:metadata` - map of thread metadata used when creating a thread
  """

  @behaviour Jido.Storage

  alias Jido.Bedrock.Storage.Checkpoints
  alias Jido.Bedrock.Storage.Options
  alias Jido.Bedrock.Storage.Telemetry
  alias Jido.Bedrock.Storage.Threads
  alias Jido.Thread
  alias Jido.Thread.Entry

  @impl true
  @spec get_checkpoint(term(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  def get_checkpoint(key, opts) do
    Telemetry.span(:checkpoint_get, %{key: key}, fn ->
      with {:ok, options} <- Options.validate(opts) do
        Checkpoints.get(key, options)
      end
    end)
  end

  @impl true
  @spec put_checkpoint(term(), term(), keyword()) :: :ok | {:error, term()}
  def put_checkpoint(key, data, opts) do
    Telemetry.span(:checkpoint_put, %{key: key}, fn ->
      with {:ok, options} <- Options.validate(opts) do
        Checkpoints.put(key, data, options)
      end
    end)
  end

  @impl true
  @spec delete_checkpoint(term(), keyword()) :: :ok | {:error, term()}
  def delete_checkpoint(key, opts) do
    Telemetry.span(:checkpoint_delete, %{key: key}, fn ->
      with {:ok, options} <- Options.validate(opts) do
        Checkpoints.delete(key, options)
      end
    end)
  end

  @impl true
  @spec load_thread(String.t(), keyword()) :: {:ok, Thread.t()} | :not_found | {:error, term()}
  def load_thread(thread_id, opts) do
    Telemetry.span(:thread_load, %{thread_id: thread_id}, fn ->
      with {:ok, options} <- Options.validate(opts) do
        Threads.load(thread_id, options)
      end
    end)
  end

  @impl true
  @spec append_thread(String.t(), [Entry.t() | map()] | Entry.t() | map(), keyword()) ::
          {:ok, Thread.t()} | {:error, term()}
  def append_thread(thread_id, entries, opts) do
    Telemetry.span(:thread_append, %{thread_id: thread_id}, fn ->
      with {:ok, options} <- Options.validate(opts, expected_rev: true, metadata: true) do
        Threads.append(thread_id, entries, options)
      end
    end)
  end

  @impl true
  @spec delete_thread(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_thread(thread_id, opts) do
    Telemetry.span(:thread_delete, %{thread_id: thread_id}, fn ->
      with {:ok, options} <- Options.validate(opts) do
        Threads.delete(thread_id, options)
      end
    end)
  end
end
