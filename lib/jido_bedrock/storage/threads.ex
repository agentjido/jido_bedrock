defmodule Jido.Bedrock.Storage.Threads do
  @moduledoc false

  alias Jido.Bedrock.Error
  alias Jido.Bedrock.Storage.Codec
  alias Jido.Bedrock.Storage.Keys
  alias Jido.Bedrock.Storage.Options
  alias Jido.Bedrock.Storage.Telemetry
  alias Jido.Bedrock.Storage.Transaction
  alias Jido.Thread
  alias Jido.Thread.Entry
  alias Jido.Thread.EntryNormalizer

  @doc false
  @spec load(String.t(), Options.t()) :: {:ok, Thread.t()} | :not_found | {:error, term()}
  def load(thread_id, %Options{} = options) do
    with :ok <- validate_thread_id(thread_id),
         result <-
           Transaction.run(options.repo, :thread_load, fn ->
             do_load(options.repo, options.prefix, thread_id)
           end) do
      unwrap(result)
    end
  end

  @doc false
  @spec append(String.t(), [Entry.t() | map()] | Entry.t() | map(), Options.t()) ::
          {:ok, Thread.t()} | {:error, term()}
  def append(thread_id, entries, %Options{} = options) do
    entries = List.wrap(entries)

    with :ok <- validate_thread_id(thread_id),
         :ok <- validate_entry_inputs(entries),
         result <-
           Transaction.run(options.repo, :thread_append, fn ->
             do_append(options.repo, options.prefix, thread_id, entries, options)
           end) do
      unwrap(result)
    end
  end

  @doc false
  @spec delete(String.t(), Options.t()) :: :ok | {:error, term()}
  def delete(thread_id, %Options{} = options) do
    with :ok <- validate_thread_id(thread_id),
         result <-
           Transaction.run(options.repo, :thread_delete, fn ->
             :ok = options.repo.clear(Keys.thread_meta_key(options.prefix, thread_id))

             {start_key, end_key} = Keys.thread_entries_range(options.prefix, thread_id)
             :ok = options.repo.clear_range({start_key, end_key})
             :ok
           end) do
      unwrap(result)
    end
  end

  defp do_load(repo, prefix, thread_id) do
    case repo.get(Keys.thread_meta_key(prefix, thread_id)) do
      nil ->
        :not_found

      encoded_meta ->
        with {:ok, meta} <- Codec.decode(encoded_meta, :thread_meta),
             :ok <- validate_meta(meta),
             {:ok, entries} <- load_entries(repo, prefix, thread_id),
             :ok <- validate_entries(meta, entries) do
          if entries == [] do
            :not_found
          else
            {:ok, reconstruct_thread(thread_id, meta, entries)}
          end
        end
    end
  end

  defp do_append(repo, prefix, thread_id, entries, %Options{} = options) do
    now = System.system_time(:millisecond)
    meta_key = Keys.thread_meta_key(prefix, thread_id)

    with {:ok, current} <- load_current(repo, prefix, thread_id, meta_key, now, options.metadata),
         :ok <- validate_expected_rev(repo, prefix, thread_id, options.expected_rev, current.rev) do
      prepared_entries = EntryNormalizer.normalize_many(entries, current.rev, now)

      Enum.each(prepared_entries, fn %Entry{} = entry ->
        :ok = repo.put(Keys.thread_entry_key(prefix, thread_id, entry.seq), Codec.encode(:thread_entry, entry))
      end)

      new_rev = current.rev + length(prepared_entries)

      meta = %{
        rev: new_rev,
        created_at: current.created_at,
        updated_at: now,
        metadata: current.metadata
      }

      :ok = repo.put(meta_key, Codec.encode(:thread_meta, meta))

      {:ok, reconstruct_thread(thread_id, meta, current.entries ++ prepared_entries)}
    end
  end

  defp load_current(repo, prefix, thread_id, meta_key, now, metadata) do
    case repo.get(meta_key) do
      nil ->
        {:ok, %{rev: 0, created_at: now, updated_at: now, metadata: metadata, entries: []}}

      encoded_meta ->
        with {:ok, meta} <- Codec.decode(encoded_meta, :thread_meta),
             :ok <- validate_meta(meta),
             {:ok, entries} <- load_entries(repo, prefix, thread_id),
             :ok <- validate_entries(meta, entries) do
          {:ok,
           %{
             rev: meta.rev,
             created_at: meta.created_at,
             updated_at: meta.updated_at,
             metadata: meta.metadata,
             entries: entries
           }}
        end
    end
  end

  defp load_entries(repo, prefix, thread_id) do
    {start_key, end_key} = Keys.thread_entries_range(prefix, thread_id)

    repo.get_range({start_key, end_key})
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, entries} ->
      with {:ok, key_seq} <- decode_entry_key_seq(prefix, thread_id, key),
           {:ok, %Entry{} = entry} <- Codec.decode(value, :thread_entry),
           :ok <- validate_entry_key_seq(key_seq, entry) do
        {:cont, {:ok, [entry | entries]}}
      else
        {:ok, other} ->
          {:halt,
           {:error,
            Error.validation_error("Stored thread entry has invalid shape",
              field: :thread_entry,
              value: other,
              details: %{expected: Jido.Thread.Entry}
            )}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, & &1.seq)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_meta(%{rev: rev, created_at: created_at, updated_at: updated_at, metadata: metadata})
       when is_integer(rev) and rev >= 0 and is_integer(created_at) and created_at >= 0 and
              is_integer(updated_at) and updated_at >= 0 and is_map(metadata) do
    :ok
  end

  defp validate_meta(meta) do
    {:error,
     Error.validation_error("Stored thread metadata has invalid shape",
       field: :thread_meta,
       value: meta,
       details: %{
         expected: %{
           rev: :non_neg_integer,
           created_at: :non_neg_integer,
           updated_at: :non_neg_integer,
           metadata: :map
         }
       }
     )}
  end

  defp validate_entries(%{rev: 0}, []), do: :ok

  defp validate_entries(%{rev: rev}, entries) do
    seqs = Enum.map(entries, & &1.seq)

    cond do
      length(entries) != rev ->
        corruption_error("Thread entry count does not match metadata revision", %{
          rev: rev,
          entry_count: length(entries),
          seqs: seqs
        })

      not contiguous_entry_seqs?(entries) ->
        corruption_error("Thread entries are not contiguous", %{rev: rev, expected: "0..#{rev - 1}", actual: seqs})

      true ->
        :ok
    end
  end

  defp decode_entry_key_seq(prefix, thread_id, key) do
    entry_prefix = Keys.thread_entries_prefix(prefix, thread_id)

    case key do
      <<^entry_prefix::binary, seq::unsigned-big-integer-size(64)>> ->
        {:ok, seq}

      _other ->
        {:error,
         Error.validation_error("Stored thread entry key has invalid shape",
           field: :thread_entry_key,
           value: key,
           details: %{expected_prefix: entry_prefix, expected_suffix_bytes: 8}
         )}
    end
  end

  defp validate_entry_key_seq(seq, %Entry{seq: seq}), do: :ok

  defp validate_entry_key_seq(key_seq, %Entry{seq: entry_seq} = entry) do
    {:error,
     Error.validation_error("Stored thread entry key does not match entry sequence",
       field: :thread_entry_key,
       value: entry,
       details: %{key_seq: key_seq, entry_seq: entry_seq}
     )}
  end

  defp contiguous_entry_seqs?(entries) do
    entries
    |> Enum.with_index()
    |> Enum.all?(fn {%Entry{seq: seq}, expected_seq} -> seq == expected_seq end)
  end

  defp validate_expected_rev(_repo, _prefix, _thread_id, nil, _current_rev), do: :ok
  defp validate_expected_rev(_repo, _prefix, _thread_id, expected_rev, expected_rev), do: :ok

  defp validate_expected_rev(repo, prefix, thread_id, expected_rev, current_rev) do
    Telemetry.emit(:thread_append, :conflict, %{}, %{
      prefix: prefix,
      thread_id: thread_id,
      expected_rev: expected_rev,
      current_rev: current_rev
    })

    Transaction.rollback(repo, :conflict)
  end

  defp validate_thread_id(thread_id) when is_binary(thread_id) and thread_id != "", do: :ok

  defp validate_thread_id(thread_id) do
    {:error,
     Error.validation_error("thread_id must be a non-empty binary",
       field: :thread_id,
       value: thread_id,
       details: %{expected: :non_empty_binary}
     )}
  end

  defp validate_entry_inputs(entries) do
    if Enum.all?(entries, &(is_map(&1) or match?(%Entry{}, &1))) do
      :ok
    else
      {:error,
       Error.validation_error("Thread entries must be maps or Jido.Thread.Entry structs",
         field: :entries,
         value: entries,
         details: %{expected: [:map, Jido.Thread.Entry]}
       )}
    end
  end

  defp corruption_error(message, details) do
    error = Error.validation_error(message, field: :thread, details: details)
    Telemetry.emit(:thread_load, :corruption, %{}, details)
    {:error, error}
  end

  defp reconstruct_thread(thread_id, meta, entries) do
    %Thread{
      id: thread_id,
      rev: meta.rev,
      entries: entries,
      created_at: meta.created_at,
      updated_at: meta.updated_at,
      metadata: meta.metadata,
      stats: %{entry_count: length(entries)}
    }
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: {:error, reason}
end
