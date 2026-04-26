defmodule Jido.Bedrock.Storage.Options do
  @moduledoc false

  alias Jido.Bedrock.Error

  @default_prefix "jido_bedrock/"

  defstruct repo: nil,
            prefix: @default_prefix,
            expected_rev: nil,
            metadata: %{}

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t(),
          expected_rev: non_neg_integer() | nil,
          metadata: map()
        }

  @doc false
  @spec validate(keyword(), keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def validate(opts, validations \\ [])

  def validate(opts, validations) when is_list(opts) do
    with {:ok, repo} <- validate_repo(opts),
         {:ok, prefix} <- validate_prefix(opts),
         {:ok, expected_rev} <- validate_expected_rev(opts, validations),
         {:ok, metadata} <- validate_metadata(opts, validations) do
      {:ok,
       %__MODULE__{
         repo: repo,
         prefix: prefix,
         expected_rev: expected_rev,
         metadata: metadata
       }}
    end
  end

  def validate(opts, _validations) do
    {:error,
     Error.config_error("Storage options must be a keyword list",
       key: :opts,
       value: opts,
       details: %{expected: :keyword}
     )}
  end

  defp validate_repo(opts) do
    case Keyword.get(opts, :repo) do
      repo when is_atom(repo) ->
        if Code.ensure_loaded?(repo) do
          {:ok, repo}
        else
          {:error, Error.config_error("Bedrock repo module is not loaded", key: :repo, value: repo)}
        end

      nil ->
        {:error, Error.config_error("Bedrock repo option is required", key: :repo, value: nil)}

      other ->
        {:error,
         Error.config_error("Bedrock repo option must be a module atom",
           key: :repo,
           value: other,
           details: %{expected: :module}
         )}
    end
  end

  defp validate_prefix(opts) do
    prefix = Keyword.get(opts, :prefix, @default_prefix)

    cond do
      not is_binary(prefix) ->
        {:error,
         Error.config_error("Storage prefix must be a binary",
           key: :prefix,
           value: prefix,
           details: %{expected: :binary}
         )}

      prefix == "" ->
        {:error, Error.config_error("Storage prefix must not be empty", key: :prefix, value: prefix)}

      not String.ends_with?(prefix, "/") ->
        {:error,
         Error.config_error("Storage prefix must end with /",
           key: :prefix,
           value: prefix,
           details: %{expected_suffix: "/"}
         )}

      true ->
        {:ok, prefix}
    end
  end

  defp validate_expected_rev(opts, validations) do
    if Keyword.get(validations, :expected_rev, false) do
      case Keyword.get(opts, :expected_rev) do
        nil ->
          {:ok, nil}

        expected_rev when is_integer(expected_rev) and expected_rev >= 0 ->
          {:ok, expected_rev}

        other ->
          {:error,
           Error.validation_error("expected_rev must be a non-negative integer",
             field: :expected_rev,
             value: other,
             details: %{expected: :non_neg_integer}
           )}
      end
    else
      {:ok, nil}
    end
  end

  defp validate_metadata(opts, validations) do
    if Keyword.get(validations, :metadata, false) do
      case Keyword.get(opts, :metadata, %{}) do
        metadata when is_map(metadata) ->
          {:ok, metadata}

        other ->
          {:error,
           Error.validation_error("metadata must be a map",
             field: :metadata,
             value: other,
             details: %{expected: :map}
           )}
      end
    else
      {:ok, %{}}
    end
  end
end
