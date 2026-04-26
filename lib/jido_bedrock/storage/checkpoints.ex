defmodule Jido.Bedrock.Storage.Checkpoints do
  @moduledoc false

  alias Jido.Bedrock.Storage.Codec
  alias Jido.Bedrock.Storage.Keys
  alias Jido.Bedrock.Storage.Options
  alias Jido.Bedrock.Storage.Transaction

  @doc false
  @spec get(term(), Options.t()) :: {:ok, term()} | :not_found | {:error, term()}
  def get(key, %Options{} = options) do
    options.repo
    |> Transaction.run(:checkpoint_get, fn ->
      case options.repo.get(Keys.checkpoint_key(options.prefix, key)) do
        nil -> :not_found
        encoded -> Codec.decode(encoded, :checkpoint)
      end
    end)
    |> unwrap()
  end

  @doc false
  @spec put(term(), term(), Options.t()) :: :ok | {:error, term()}
  def put(key, data, %Options{} = options) do
    encoded = Codec.encode(:checkpoint, data)

    options.repo
    |> Transaction.run(:checkpoint_put, fn ->
      :ok = options.repo.put(Keys.checkpoint_key(options.prefix, key), encoded)
      :ok
    end)
    |> unwrap()
  end

  @doc false
  @spec delete(term(), Options.t()) :: :ok | {:error, term()}
  def delete(key, %Options{} = options) do
    options.repo
    |> Transaction.run(:checkpoint_delete, fn ->
      :ok = options.repo.clear(Keys.checkpoint_key(options.prefix, key))
      :ok
    end)
    |> unwrap()
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: {:error, reason}
end
