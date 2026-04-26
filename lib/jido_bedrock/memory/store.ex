defmodule Jido.Bedrock.Memory.Store do
  @moduledoc """
  Bedrock-backed `Jido.Memory.Store` adapter.

  This adapter lets `jido_memory`'s built-in basic provider and
  `Jido.Memory.BasicPlugin` persist canonical memory records in Bedrock.

  Required options:

  - `:repo` - loaded module implementing the `Bedrock.Repo` API

  Optional options:

  - `:prefix` - non-empty key prefix ending in `/` (default: `"jido_bedrock/"`)
  - `:ttl` - positive store-level TTL in milliseconds, applied at write time

  Example:

      {Jido.Memory.BasicPlugin,
       %{
         store: {Jido.Bedrock.Memory.Store, repo: MyApp.BedrockRepo, prefix: "my_app/jido/"}
       }}
  """

  if Code.ensure_loaded?(Jido.Memory.Store) do
    @behaviour Jido.Memory.Store
  end

  alias Jido.Bedrock.Error
  alias Jido.Bedrock.Memory.Options
  alias Jido.Bedrock.Memory.Records
  alias Jido.Bedrock.Storage.Telemetry

  @doc false
  @spec ensure_ready(keyword()) :: :ok | {:error, term()}
  def ensure_ready(opts) do
    Telemetry.span(:memory_ensure_ready, %{}, fn ->
      with :ok <- ensure_jido_memory_loaded(),
           {:ok, options} <- Options.validate(opts) do
        Records.ensure_ready(options)
      end
    end)
  end

  @doc false
  @spec validate_options(keyword()) :: :ok | {:error, term()}
  def validate_options(opts) do
    with :ok <- ensure_jido_memory_loaded(),
         {:ok, _options} <- Options.validate(opts) do
      :ok
    end
  end

  @doc false
  @spec put(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def put(%{__struct__: Jido.Memory.Record, namespace: namespace, id: id} = record, opts) do
    Telemetry.span(:memory_put, %{namespace: namespace, id: id}, fn ->
      with :ok <- ensure_jido_memory_loaded(),
           {:ok, options} <- Options.validate(opts) do
        Records.put(record, options)
      end
    end)
  end

  def put(record, _opts) do
    {:error,
     Error.validation_error("Memory store put expects a Jido.Memory.Record struct",
       field: :memory_record,
       value: record,
       details: %{expected: Jido.Memory.Record}
     )}
  end

  @doc false
  @spec get({String.t(), String.t()}, keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  def get({namespace, id}, opts) when is_binary(namespace) and is_binary(id) do
    Telemetry.span(:memory_get, %{namespace: namespace, id: id}, fn ->
      with :ok <- ensure_jido_memory_loaded(),
           {:ok, options} <- Options.validate(opts) do
        Records.get(namespace, id, options)
      end
    end)
  end

  def get(key, _opts) do
    {:error,
     Error.validation_error("Memory store get expects {namespace, id}",
       field: :memory_key,
       value: key,
       details: %{expected: {":binary", ":binary"}}
     )}
  end

  @doc false
  @spec delete({String.t(), String.t()}, keyword()) :: :ok | {:error, term()}
  def delete({namespace, id}, opts) when is_binary(namespace) and is_binary(id) do
    Telemetry.span(:memory_delete, %{namespace: namespace, id: id}, fn ->
      with :ok <- ensure_jido_memory_loaded(),
           {:ok, options} <- Options.validate(opts) do
        Records.delete(namespace, id, options)
      end
    end)
  end

  def delete(key, _opts) do
    {:error,
     Error.validation_error("Memory store delete expects {namespace, id}",
       field: :memory_key,
       value: key,
       details: %{expected: {":binary", ":binary"}}
     )}
  end

  @doc false
  @spec query(term(), keyword()) :: {:ok, [term()]} | {:error, term()}
  def query(%{__struct__: Jido.Memory.Query, namespace: nil}, _opts), do: {:error, :namespace_required}

  def query(%{__struct__: Jido.Memory.Query, namespace: namespace} = query, opts) do
    Telemetry.span(:memory_query, %{namespace: namespace}, fn ->
      with :ok <- ensure_jido_memory_loaded(),
           {:ok, options} <- Options.validate(opts) do
        Records.query(query, options)
      end
    end)
  end

  def query(query, _opts) do
    {:error,
     Error.validation_error("Memory store query expects a Jido.Memory.Query struct",
       field: :memory_query,
       value: query,
       details: %{expected: Jido.Memory.Query}
     )}
  end

  @doc false
  @spec prune_expired(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune_expired(opts) do
    Telemetry.span(:memory_prune_expired, %{}, fn ->
      with :ok <- ensure_jido_memory_loaded(),
           {:ok, options} <- Options.validate(opts) do
        Records.prune_expired(options)
      end
    end)
  end

  defp ensure_jido_memory_loaded do
    required = [Jido.Memory.Store, Jido.Memory.Record, Jido.Memory.Query]

    missing =
      Enum.reject(required, fn module ->
        Code.ensure_loaded?(module)
      end)

    if missing == [] do
      :ok
    else
      {:error,
       Error.config_error("jido_memory is required to use the Bedrock memory store",
         key: :jido_memory,
         value: missing,
         details: %{missing_modules: missing}
       )}
    end
  end
end
