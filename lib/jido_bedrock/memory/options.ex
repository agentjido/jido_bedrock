defmodule Jido.Bedrock.Memory.Options do
  @moduledoc false

  alias Jido.Bedrock.Error
  alias Jido.Bedrock.Storage.Options, as: StorageOptions

  defstruct repo: nil,
            prefix: nil,
            ttl: nil

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t(),
          ttl: pos_integer() | nil
        }

  @doc false
  @spec validate(keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def validate(opts) when is_list(opts) do
    with {:ok, storage_options} <- StorageOptions.validate(opts),
         {:ok, ttl} <- validate_ttl(opts) do
      {:ok,
       %__MODULE__{
         repo: storage_options.repo,
         prefix: storage_options.prefix,
         ttl: ttl
       }}
    end
  end

  def validate(opts) do
    {:error,
     Error.config_error("Memory store options must be a keyword list",
       key: :opts,
       value: opts,
       details: %{expected: :keyword}
     )}
  end

  defp validate_ttl(opts) do
    case Keyword.get(opts, :ttl) do
      nil ->
        {:ok, nil}

      ttl when is_integer(ttl) and ttl > 0 ->
        {:ok, ttl}

      other ->
        {:error,
         Error.validation_error("Memory ttl must be a positive integer in milliseconds",
           field: :ttl,
           value: other,
           details: %{expected: :pos_integer}
         )}
    end
  end
end
