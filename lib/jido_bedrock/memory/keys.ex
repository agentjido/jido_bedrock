defmodule Jido.Bedrock.Memory.Keys do
  @moduledoc false

  alias Jido.Bedrock.Storage.Keys, as: StorageKeys

  @score_offset 9_223_372_036_854_775_808
  @min_score -9_223_372_036_854_775_808
  @max_score 9_223_372_036_854_775_807

  @doc false
  @spec record_key(String.t(), String.t(), String.t()) :: binary()
  def record_key(prefix, namespace, id),
    do: memory_prefix(prefix) <> "records/" <> component(namespace) <> "/" <> component(id)

  @doc false
  @spec meta_key(String.t(), String.t(), String.t()) :: binary()
  def meta_key(prefix, namespace, id),
    do: memory_prefix(prefix) <> "meta/" <> component(namespace) <> "/" <> component(id)

  @doc false
  @spec namespace_time_key(String.t(), String.t(), integer(), String.t()) :: binary()
  def namespace_time_key(prefix, namespace, observed_at, id) do
    namespace_time_prefix(prefix, namespace) <> encode_score!(observed_at) <> "/" <> component(id)
  end

  @doc false
  @spec namespace_time_range(String.t(), String.t(), integer() | nil, integer() | nil) :: {binary(), binary()}
  def namespace_time_range(prefix, namespace, since, until) do
    score_range(namespace_time_prefix(prefix, namespace), since, until)
  end

  @doc false
  @spec namespace_class_time_key(String.t(), String.t(), term(), integer(), String.t()) :: binary()
  def namespace_class_time_key(prefix, namespace, class, observed_at, id) do
    namespace_class_time_prefix(prefix, namespace, class) <> encode_score!(observed_at) <> "/" <> component(id)
  end

  @doc false
  @spec namespace_class_time_range(String.t(), String.t(), term(), integer() | nil, integer() | nil) ::
          {binary(), binary()}
  def namespace_class_time_range(prefix, namespace, class, since, until) do
    score_range(namespace_class_time_prefix(prefix, namespace, class), since, until)
  end

  @doc false
  @spec namespace_tag_key(String.t(), String.t(), String.t(), String.t()) :: binary()
  def namespace_tag_key(prefix, namespace, tag, id) do
    namespace_tag_prefix(prefix, namespace, tag) <> component(id)
  end

  @doc false
  @spec namespace_tag_range(String.t(), String.t(), String.t()) :: {binary(), binary()}
  def namespace_tag_range(prefix, namespace, tag), do: full_range(namespace_tag_prefix(prefix, namespace, tag))

  @doc false
  @spec expires_key(String.t(), integer(), String.t(), String.t()) :: binary()
  def expires_key(prefix, cleanup_at, namespace, id) do
    expires_prefix(prefix) <> encode_score!(cleanup_at) <> "/" <> component(namespace) <> "/" <> component(id)
  end

  @doc false
  @spec expires_range(String.t(), integer() | nil, integer() | nil) :: {binary(), binary()}
  def expires_range(prefix, since, until), do: score_range(expires_prefix(prefix), since, until)

  @doc false
  @spec valid_score?(term()) :: boolean()
  def valid_score?(score), do: is_integer(score) and score >= @min_score and score <= @max_score

  defp memory_prefix(prefix), do: prefix <> "memory/"

  defp namespace_time_prefix(prefix, namespace),
    do: memory_prefix(prefix) <> "indexes/ns_time/" <> component(namespace) <> "/"

  defp namespace_class_time_prefix(prefix, namespace, class),
    do: memory_prefix(prefix) <> "indexes/ns_class_time/" <> component(namespace) <> "/" <> component(class) <> "/"

  defp namespace_tag_prefix(prefix, namespace, tag),
    do: memory_prefix(prefix) <> "indexes/ns_tag/" <> component(namespace) <> "/" <> component(tag) <> "/"

  defp expires_prefix(prefix), do: memory_prefix(prefix) <> "indexes/expires/"

  defp component(value), do: StorageKeys.encode_key_component(value)

  defp full_range(prefix), do: {prefix, Bedrock.Key.strinc(prefix)}

  defp score_range(prefix, since, until) do
    start_key = if is_integer(since), do: prefix <> encode_score!(since), else: prefix

    end_key =
      if is_integer(until) do
        prefix <> encode_score!(until) <> <<255>>
      else
        Bedrock.Key.strinc(prefix)
      end

    {start_key, end_key}
  end

  defp encode_score!(score) when score >= @min_score and score <= @max_score do
    <<score + @score_offset::unsigned-big-integer-size(64)>>
  end
end
