defmodule Jido.Bedrock.Storage.Codec do
  @moduledoc false

  alias Jido.Bedrock.Error

  @version 1
  @types [:checkpoint, :thread_meta, :thread_entry, :memory_record, :memory_meta, :memory_index]

  @type envelope_type :: :checkpoint | :thread_meta | :thread_entry | :memory_record | :memory_meta | :memory_index

  @doc false
  @spec encode(envelope_type(), term()) :: binary()
  def encode(type, data) when type in @types do
    :erlang.term_to_binary(%{version: @version, type: type, data: data})
  end

  @doc false
  @spec decode(binary(), envelope_type()) :: {:ok, term()} | {:error, Exception.t()}
  def decode(binary, expected_type) when is_binary(binary) and expected_type in @types do
    with {:ok, envelope} <- decode_binary(binary),
         :ok <- validate_envelope(envelope, expected_type) do
      {:ok, Map.fetch!(envelope, :data)}
    end
  end

  def decode(value, expected_type) do
    {:error,
     Error.validation_error("Stored value must be an encoded binary",
       field: :value,
       value: value,
       details: %{expected_type: expected_type}
     )}
  end

  @doc false
  @spec version() :: pos_integer()
  def version, do: @version

  @doc false
  @spec envelope(term(), term()) :: map()
  def envelope(type, data), do: %{version: @version, type: type, data: data}

  defp decode_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    error ->
      {:error,
       Error.validation_error("Stored value is not a valid Erlang external term",
         field: :value,
         details: %{reason: error}
       )}
  end

  defp validate_envelope(%{version: @version, type: expected_type, data: _data}, expected_type), do: :ok

  defp validate_envelope(%{version: version}, _expected_type) when version != @version do
    {:error,
     Error.validation_error("Unsupported storage envelope version",
       field: :version,
       value: version,
       details: %{supported: [@version]}
     )}
  end

  defp validate_envelope(%{type: type}, expected_type) when type != expected_type do
    {:error,
     Error.validation_error("Unexpected storage envelope type",
       field: :type,
       value: type,
       details: %{expected: expected_type}
     )}
  end

  defp validate_envelope(envelope, expected_type) do
    {:error,
     Error.validation_error("Stored value is not a valid jido_bedrock envelope",
       field: :envelope,
       value: envelope,
       details: %{expected_type: expected_type, expected_version: @version}
     )}
  end
end
