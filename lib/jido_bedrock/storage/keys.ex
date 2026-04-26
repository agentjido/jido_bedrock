defmodule Jido.Bedrock.Storage.Keys do
  @moduledoc false

  @doc false
  @spec checkpoint_key(String.t(), term()) :: binary()
  def checkpoint_key(prefix, key), do: prefix <> "checkpoints/" <> encode_key_component(key)

  @doc false
  @spec thread_meta_key(String.t(), String.t()) :: binary()
  def thread_meta_key(prefix, thread_id),
    do: prefix <> "threads/" <> encode_key_component(thread_id) <> "/meta"

  @doc false
  @spec thread_entry_key(String.t(), String.t(), non_neg_integer()) :: binary()
  def thread_entry_key(prefix, thread_id, seq) do
    thread_entries_prefix(prefix, thread_id) <> <<seq::unsigned-big-integer-size(64)>>
  end

  @doc false
  @spec thread_entries_range(String.t(), String.t()) :: {binary(), binary()}
  def thread_entries_range(prefix, thread_id) do
    start_key = thread_entries_prefix(prefix, thread_id)
    end_key = Bedrock.Key.strinc(start_key)
    {start_key, end_key}
  end

  @doc false
  @spec thread_entries_prefix(String.t(), String.t()) :: binary()
  def thread_entries_prefix(prefix, thread_id),
    do: prefix <> "threads/" <> encode_key_component(thread_id) <> "/entries/"

  @doc false
  @spec encode_key_component(term()) :: binary()
  def encode_key_component(term) do
    term
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end
end
