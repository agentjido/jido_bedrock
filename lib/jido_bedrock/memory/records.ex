defmodule Jido.Bedrock.Memory.Records do
  @moduledoc false

  alias Jido.Bedrock.Error
  alias Jido.Bedrock.Memory.Keys
  alias Jido.Bedrock.Memory.Options
  alias Jido.Bedrock.Storage.Codec
  alias Jido.Bedrock.Storage.Transaction

  @doc false
  @spec ensure_ready(Options.t()) :: :ok | {:error, term()}
  def ensure_ready(%Options{} = options) do
    options.repo
    |> Transaction.run(:memory_ensure_ready, fn -> :ok end)
    |> unwrap()
  end

  @doc false
  @spec put(term(), Options.t()) :: {:ok, term()} | {:error, term()}
  def put(record, %Options{} = options) do
    with :ok <- validate_record(record),
         result <-
           Transaction.run(options.repo, :memory_put, fn ->
             do_put(options.repo, record, options)
           end) do
      unwrap(result)
    end
  end

  @doc false
  @spec get(String.t(), String.t(), Options.t()) :: {:ok, term()} | :not_found | {:error, term()}
  def get(namespace, id, %Options{} = options) do
    with :ok <- validate_key({namespace, id}),
         result <-
           Transaction.run(options.repo, :memory_get, fn ->
             fetch_record(options.repo, namespace, id, options)
           end) do
      unwrap(result)
    end
  end

  @doc false
  @spec delete(String.t(), String.t(), Options.t()) :: :ok | {:error, term()}
  def delete(namespace, id, %Options{} = options) do
    with :ok <- validate_key({namespace, id}),
         result <-
           Transaction.run(options.repo, :memory_delete, fn ->
             do_delete(options.repo, namespace, id, options)
           end) do
      unwrap(result)
    end
  end

  @doc false
  @spec query(term(), Options.t()) :: {:ok, [term()]} | {:error, term()}
  def query(%{namespace: nil}, _options), do: {:error, :namespace_required}

  def query(query, %Options{} = options) do
    with :ok <- validate_query(query),
         result <-
           Transaction.run(options.repo, :memory_query, fn ->
             do_query(options.repo, query, options)
           end) do
      unwrap(result)
    end
  end

  @doc false
  @spec prune_expired(Options.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune_expired(%Options{} = options) do
    result =
      Transaction.run(options.repo, :memory_prune_expired, fn ->
        do_prune_expired(options.repo, options, System.system_time(:millisecond))
      end)

    unwrap(result)
  end

  defp do_put(repo, record, %Options{} = options) do
    now = System.system_time(:millisecond)

    with {:ok, metadata} <- build_index_metadata(record, options, now),
         {:ok, existing_metadata} <- load_deindex_metadata(repo, record.namespace, record.id, options),
         :ok <- deindex_record(repo, record.namespace, record.id, existing_metadata, options) do
      :ok = repo.put(Keys.record_key(options.prefix, record.namespace, record.id), Codec.encode(:memory_record, record))
      :ok = repo.put(Keys.meta_key(options.prefix, record.namespace, record.id), Codec.encode(:memory_meta, metadata))

      Enum.each(index_keys(record.namespace, record.id, metadata, options), fn key ->
        :ok = repo.put(key, Codec.encode(:memory_index, %{namespace: record.namespace, id: record.id}))
      end)

      {:ok, record}
    end
  end

  defp fetch_record(repo, namespace, id, %Options{} = options) do
    record_key = Keys.record_key(options.prefix, namespace, id)

    case repo.get(record_key) do
      nil ->
        with {:ok, metadata} <- load_index_metadata(repo, namespace, id, options),
             :ok <- deindex_record(repo, namespace, id, metadata, options),
             :ok <- clear_record_keys(repo, namespace, id, options) do
          :not_found
        end

      encoded ->
        with {:ok, record} <- decode_record(encoded),
             :ok <- validate_record(record),
             {:ok, metadata} <- load_index_metadata(repo, namespace, id, options) do
          if expired?(record, metadata) do
            case do_delete(repo, namespace, id, options) do
              :ok -> :not_found
              {:error, _reason} = error -> error
            end
          else
            {:ok, record}
          end
        end
    end
  end

  defp do_delete(repo, namespace, id, %Options{} = options) do
    with {:ok, metadata} <- load_deindex_metadata(repo, namespace, id, options),
         :ok <- deindex_record(repo, namespace, id, metadata, options),
         :ok <- clear_record_keys(repo, namespace, id, options) do
      :ok
    end
  end

  defp do_query(repo, query, %Options{} = options) do
    with {:ok, candidate_sources} <- build_candidate_sources(repo, query, options),
         {:ok, records} <- load_matching_records(repo, pick_narrowest_ids(candidate_sources), query, options) do
      {:ok,
       records
       |> sort_records(query.order)
       |> Enum.take(query.limit)}
    end
  end

  defp do_prune_expired(repo, %Options{} = options, now) do
    with {:ok, entries} <- index_entries(repo.get_range(Keys.expires_range(options.prefix, nil, now))) do
      Enum.reduce_while(entries, {:ok, 0}, fn {key, namespace, id}, {:ok, count} ->
        case load_index_metadata(repo, namespace, id, options) do
          {:ok, %{cleanup_at: cleanup_at}} when is_integer(cleanup_at) and cleanup_at <= now ->
            case do_delete(repo, namespace, id, options) do
              :ok -> {:cont, {:ok, count + 1}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:ok, _metadata} ->
            :ok = repo.clear(key)
            {:cont, {:ok, count}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp build_candidate_sources(repo, query, %Options{} = options) do
    with {:ok, base} <-
           ids_from_range(repo, Keys.namespace_time_range(options.prefix, query.namespace, query.since, query.until)),
         {:ok, class_sources} <- class_sources(repo, query, options),
         {:ok, tags_any_sources} <- tags_any_sources(repo, query, options),
         {:ok, tags_all_sources} <- tags_all_sources(repo, query, options) do
      {:ok, [{:namespace_time, base}] ++ class_sources ++ tags_any_sources ++ tags_all_sources}
    end
  end

  defp class_sources(_repo, %{classes: []}, _options), do: {:ok, []}

  defp class_sources(repo, query, %Options{} = options) do
    query.classes
    |> Enum.reduce_while({:ok, MapSet.new()}, fn class, {:ok, acc} ->
      range = Keys.namespace_class_time_range(options.prefix, query.namespace, class, query.since, query.until)

      case ids_from_range(repo, range) do
        {:ok, ids} -> {:cont, {:ok, MapSet.union(acc, ids)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, [{:class, ids}]}
      {:error, _reason} = error -> error
    end
  end

  defp tags_any_sources(_repo, %{tags_any: []}, _options), do: {:ok, []}

  defp tags_any_sources(repo, query, %Options{} = options) do
    query.tags_any
    |> Enum.reduce_while({:ok, MapSet.new()}, fn tag, {:ok, acc} ->
      case ids_from_range(repo, Keys.namespace_tag_range(options.prefix, query.namespace, tag)) do
        {:ok, ids} -> {:cont, {:ok, MapSet.union(acc, ids)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, [{:tags_any, ids}]}
      {:error, _reason} = error -> error
    end
  end

  defp tags_all_sources(_repo, %{tags_all: []}, _options), do: {:ok, []}

  defp tags_all_sources(repo, %{tags_all: [first | rest]} = query, %Options{} = options) do
    first_range = Keys.namespace_tag_range(options.prefix, query.namespace, first)

    with {:ok, initial} <- ids_from_range(repo, first_range) do
      rest
      |> Enum.reduce_while({:ok, initial}, fn tag, {:ok, acc} ->
        case ids_from_range(repo, Keys.namespace_tag_range(options.prefix, query.namespace, tag)) do
          {:ok, ids} -> {:cont, {:ok, MapSet.intersection(acc, ids)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, ids} -> {:ok, [{:tags_all, ids}]}
        {:error, _reason} = error -> error
      end
    end
  end

  defp ids_from_range(repo, range) do
    with {:ok, entries} <- index_entries(repo.get_range(range)) do
      {:ok, entries |> Enum.map(fn {_key, _namespace, id} -> id end) |> MapSet.new()}
    end
  end

  defp index_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case Codec.decode(value, :memory_index) do
        {:ok, %{namespace: namespace, id: id}} when is_binary(namespace) and is_binary(id) ->
          {:cont, {:ok, [{key, namespace, id} | acc]}}

        {:ok, other} ->
          {:halt,
           {:error,
            Error.validation_error("Stored memory index has invalid shape",
              field: :memory_index,
              value: other,
              details: %{expected: %{namespace: :binary, id: :binary}}
            )}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp load_matching_records(repo, ids, query, %Options{} = options) do
    ids
    |> MapSet.to_list()
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case fetch_record(repo, query.namespace, id, options) do
        {:ok, record} ->
          if record_matches?(record, query), do: {:cont, {:ok, [record | acc]}}, else: {:cont, {:ok, acc}}

        :not_found ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp load_deindex_metadata(repo, namespace, id, %Options{} = options) do
    case load_index_metadata(repo, namespace, id, options) do
      {:ok, nil} ->
        repo
        |> fetch_existing_record(namespace, id, options)
        |> case do
          {:ok, record} -> build_index_metadata(record, %{options | ttl: nil}, System.system_time(:millisecond))
          :not_found -> {:ok, nil}
          {:error, _reason} = error -> error
        end

      {:ok, metadata} ->
        {:ok, metadata}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_existing_record(repo, namespace, id, %Options{} = options) do
    case repo.get(Keys.record_key(options.prefix, namespace, id)) do
      nil ->
        :not_found

      encoded ->
        with {:ok, record} <- decode_record(encoded),
             :ok <- validate_record(record) do
          {:ok, record}
        end
    end
  end

  defp load_index_metadata(repo, namespace, id, %Options{} = options) do
    case repo.get(Keys.meta_key(options.prefix, namespace, id)) do
      nil ->
        {:ok, nil}

      encoded ->
        with {:ok, metadata} <- Codec.decode(encoded, :memory_meta),
             :ok <- validate_index_metadata(metadata) do
          {:ok, metadata}
        end
    end
  end

  defp build_index_metadata(record, %Options{} = options, now) do
    cleanup_at =
      [record.expires_at, options.ttl && now + options.ttl]
      |> Enum.filter(&is_integer/1)
      |> case do
        [] -> nil
        values -> Enum.min(values)
      end

    metadata = %{
      observed_at: record.observed_at,
      class: record.class,
      tags: record.tags,
      cleanup_at: cleanup_at
    }

    with :ok <- validate_index_metadata(metadata) do
      {:ok, metadata}
    end
  end

  defp validate_index_metadata(%{observed_at: observed_at, class: _class, tags: tags, cleanup_at: cleanup_at})
       when is_list(tags) do
    cond do
      not Keys.valid_score?(observed_at) ->
        invalid_memory(:memory_meta, %{observed_at: observed_at}, %{observed_at: :signed_64_bit_integer})

      not Enum.all?(tags, &is_binary/1) ->
        invalid_memory(:memory_meta, %{tags: tags}, %{tags: [:binary]})

      not (is_nil(cleanup_at) or Keys.valid_score?(cleanup_at)) ->
        invalid_memory(:memory_meta, %{cleanup_at: cleanup_at}, %{cleanup_at: :signed_64_bit_integer_or_nil})

      true ->
        :ok
    end
  end

  defp validate_index_metadata(metadata) do
    invalid_memory(:memory_meta, metadata, %{observed_at: :integer, class: :term, tags: [:binary], cleanup_at: :integer})
  end

  defp deindex_record(_repo, _namespace, _id, nil, _options), do: :ok

  defp deindex_record(repo, namespace, id, metadata, %Options{} = options) do
    namespace
    |> index_keys(id, metadata, options)
    |> Enum.each(fn key -> :ok = repo.clear(key) end)

    :ok
  end

  defp clear_record_keys(repo, namespace, id, %Options{} = options) do
    :ok = repo.clear(Keys.record_key(options.prefix, namespace, id))
    :ok = repo.clear(Keys.meta_key(options.prefix, namespace, id))
    :ok
  end

  defp index_keys(namespace, id, metadata, %Options{} = options) do
    [
      Keys.namespace_time_key(options.prefix, namespace, metadata.observed_at, id),
      Keys.namespace_class_time_key(options.prefix, namespace, metadata.class, metadata.observed_at, id)
    ] ++
      Enum.map(metadata.tags, fn tag -> Keys.namespace_tag_key(options.prefix, namespace, tag, id) end) ++
      expiry_key(options.prefix, namespace, id, metadata.cleanup_at)
  end

  defp expiry_key(_prefix, _namespace, _id, nil), do: []
  defp expiry_key(prefix, namespace, id, cleanup_at), do: [Keys.expires_key(prefix, cleanup_at, namespace, id)]

  defp pick_narrowest_ids(sources) do
    {_source, ids} =
      Enum.min_by(sources, fn {_name, set} ->
        MapSet.size(set)
      end)

    ids
  end

  defp record_matches?(record, query) do
    class_matches?(record, query.classes) and
      kind_matches?(record, query.kinds) and
      tags_any_match?(record, query.tags_any) and
      tags_all_match?(record, query.tags_all) and
      time_matches?(record, query.since, query.until) and
      text_matches?(record, query.text_contains)
  end

  defp class_matches?(_record, []), do: true
  defp class_matches?(record, classes), do: record.class in classes

  defp kind_matches?(_record, []), do: true

  defp kind_matches?(record, kinds) do
    record_kind = kind_key(record.kind)
    Enum.any?(kinds, &(kind_key(&1) == record_kind))
  end

  defp tags_any_match?(_record, []), do: true
  defp tags_any_match?(record, tags_any), do: Enum.any?(tags_any, &(&1 in record.tags))

  defp tags_all_match?(_record, []), do: true
  defp tags_all_match?(record, tags_all), do: Enum.all?(tags_all, &(&1 in record.tags))

  defp time_matches?(record, since, until) do
    lower_ok = if is_integer(since), do: record.observed_at >= since, else: true
    upper_ok = if is_integer(until), do: record.observed_at <= until, else: true
    lower_ok and upper_ok
  end

  defp text_matches?(_record, nil), do: true

  defp text_matches?(record, filter) do
    filter = String.downcase(filter)

    haystack =
      cond do
        is_binary(record.text) and record.text != "" -> record.text
        true -> inspect(record.content)
      end

    haystack
    |> String.downcase()
    |> String.contains?(filter)
  end

  defp sort_records(records, :asc), do: Enum.sort_by(records, &{&1.observed_at, &1.id}, :asc)
  defp sort_records(records, :desc), do: Enum.sort_by(records, &{&1.observed_at, &1.id}, :desc)

  defp expired?(_record, %{cleanup_at: cleanup_at}) when is_integer(cleanup_at),
    do: cleanup_at <= System.system_time(:millisecond)

  defp expired?(%{expires_at: expires_at}, _metadata) when is_integer(expires_at),
    do: expires_at <= System.system_time(:millisecond)

  defp expired?(_record, _metadata), do: false

  defp decode_record(encoded) do
    case Codec.decode(encoded, :memory_record) do
      {:ok, %{__struct__: Jido.Memory.Record} = record} ->
        {:ok, record}

      {:ok, other} ->
        {:error,
         Error.validation_error("Stored memory record has invalid shape",
           field: :memory_record,
           value: other,
           details: %{expected: Jido.Memory.Record}
         )}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_record(%{
         __struct__: Jido.Memory.Record,
         namespace: namespace,
         id: id,
         observed_at: observed_at,
         expires_at: expires_at,
         tags: tags,
         metadata: metadata
       }) do
    cond do
      not (is_binary(namespace) and namespace != "") ->
        invalid_memory(:memory_record, %{namespace: namespace}, %{namespace: :non_empty_binary})

      not (is_binary(id) and id != "") ->
        invalid_memory(:memory_record, %{id: id}, %{id: :non_empty_binary})

      not Keys.valid_score?(observed_at) ->
        invalid_memory(:memory_record, %{observed_at: observed_at}, %{observed_at: :signed_64_bit_integer})

      not (is_nil(expires_at) or Keys.valid_score?(expires_at)) ->
        invalid_memory(:memory_record, %{expires_at: expires_at}, %{expires_at: :signed_64_bit_integer_or_nil})

      not (is_list(tags) and Enum.all?(tags, &is_binary/1)) ->
        invalid_memory(:memory_record, %{tags: tags}, %{tags: [:binary]})

      not is_map(metadata) ->
        invalid_memory(:memory_record, %{metadata: metadata}, %{metadata: :map})

      true ->
        :ok
    end
  end

  defp validate_record(record) do
    invalid_memory(:memory_record, record, %{expected: Jido.Memory.Record})
  end

  defp validate_key({namespace, id}) when is_binary(namespace) and namespace != "" and is_binary(id) and id != "",
    do: :ok

  defp validate_key(key) do
    {:error,
     Error.validation_error("Memory key must be {namespace, id} with non-empty binaries",
       field: :memory_key,
       value: key,
       details: %{expected: {":non_empty_binary", ":non_empty_binary"}}
     )}
  end

  defp validate_query(%{
         __struct__: Jido.Memory.Query,
         namespace: namespace,
         classes: classes,
         kinds: kinds,
         tags_any: tags_any,
         tags_all: tags_all,
         since: since,
         until: until,
         text_contains: text_contains,
         limit: limit,
         order: order
       })
       when is_binary(namespace) and namespace != "" and is_list(classes) and is_list(kinds) and is_list(tags_any) and
              is_list(tags_all) and is_integer(limit) and limit > 0 and order in [:asc, :desc] do
    cond do
      not (is_nil(since) or Keys.valid_score?(since)) ->
        invalid_memory(:memory_query, %{since: since}, %{since: :signed_64_bit_integer_or_nil})

      not (is_nil(until) or Keys.valid_score?(until)) ->
        invalid_memory(:memory_query, %{until: until}, %{until: :signed_64_bit_integer_or_nil})

      not Enum.all?(tags_any ++ tags_all, &is_binary/1) ->
        invalid_memory(:memory_query, %{tags_any: tags_any, tags_all: tags_all}, %{tags: [:binary]})

      not (is_nil(text_contains) or is_binary(text_contains)) ->
        invalid_memory(:memory_query, %{text_contains: text_contains}, %{text_contains: :binary_or_nil})

      true ->
        :ok
    end
  end

  defp validate_query(query) do
    invalid_memory(:memory_query, query, %{expected: Jido.Memory.Query})
  end

  defp invalid_memory(field, value, expected) do
    {:error,
     Error.validation_error("Invalid Bedrock memory data",
       field: field,
       value: value,
       details: %{expected: expected}
     )}
  end

  defp kind_key(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp kind_key(kind) when is_binary(kind), do: kind
  defp kind_key(kind), do: inspect(kind)

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: {:error, reason}
end
