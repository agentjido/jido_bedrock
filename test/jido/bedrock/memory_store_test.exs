defmodule Jido.Bedrock.MemoryStoreTest do
  use Jido.Bedrock.Case, async: false

  alias Jido.Bedrock.Error
  alias Jido.Bedrock.Memory.Keys, as: MemoryKeys
  alias Jido.Bedrock.Memory.Options, as: MemoryOptions
  alias Jido.Bedrock.Memory.Records, as: MemoryRecords
  alias Jido.Bedrock.Memory.Store, as: MemoryStore
  alias Jido.Bedrock.Storage.Codec
  alias Jido.Memory.Query
  alias Jido.Memory.Record
  alias Jido.Memory.RetrieveResult
  alias Jido.Memory.Runtime

  @namespace "agent:bedrock-memory"
  @too_large_score 9_223_372_036_854_775_808

  describe "option validation" do
    test "validates repo prefix and ttl", %{storage_opts: storage_opts} do
      assert :ok = MemoryStore.validate_options(storage_opts)

      assert {:error, %Error.ConfigError{key: :repo}} = MemoryStore.validate_options([])

      assert {:error, %Error.ConfigError{key: :prefix}} =
               MemoryStore.validate_options(repo: FakeRepo, prefix: "missing-slash")

      assert {:error, %Error.InvalidInputError{field: :ttl}} =
               MemoryStore.validate_options(Keyword.put(storage_opts, :ttl, 0))

      assert {:error, %Error.ConfigError{key: :opts}} = MemoryStore.validate_options(:not_options)
    end
  end

  describe "record lifecycle" do
    test "exposes public adapter helpers" do
      assert Jido.Bedrock.memory_store_adapter() == MemoryStore
      assert JidoBedrock.memory_store_adapter() == MemoryStore
    end

    test "stores records in versioned envelopes and supports get/delete", %{storage_opts: storage_opts} do
      record = memory_record(%{id: unique_id("memory"), text: "The user prefers concise answers."})

      assert {:ok, ^record} = MemoryStore.put(record, storage_opts)
      assert {:ok, ^record} = MemoryStore.get({record.namespace, record.id}, storage_opts)

      encoded = FakeRepo.get(MemoryKeys.record_key(storage_opts[:prefix], record.namespace, record.id))
      assert {:ok, ^record} = Codec.decode(encoded, :memory_record)

      assert :ok = MemoryStore.delete({record.namespace, record.id}, storage_opts)
      assert :not_found = MemoryStore.get({record.namespace, record.id}, storage_opts)
    end

    test "rejects legacy raw-term record values", %{storage_opts: storage_opts} do
      record = memory_record(%{id: unique_id("legacy"), text: "raw term"})
      key = MemoryKeys.record_key(storage_opts[:prefix], record.namespace, record.id)

      :ok = FakeRepo.put(key, :erlang.term_to_binary(record))

      assert {:error, %Error.InvalidInputError{field: :envelope}} =
               MemoryStore.get({record.namespace, record.id}, storage_opts)
    end

    test "rejects malformed stored memory records and metadata", %{storage_opts: storage_opts} do
      record = memory_record(%{id: unique_id("bad-stored"), text: "bad stored"})
      record_key = MemoryKeys.record_key(storage_opts[:prefix], record.namespace, record.id)
      meta_key = MemoryKeys.meta_key(storage_opts[:prefix], record.namespace, record.id)

      :ok = FakeRepo.put(record_key, Codec.encode(:memory_record, %{not: :record}))

      assert {:error, %Error.InvalidInputError{field: :memory_record}} =
               MemoryStore.get({record.namespace, record.id}, storage_opts)

      FakeRepo.reset()
      :ok = FakeRepo.put(record_key, Codec.encode(:memory_record, record))

      :ok =
        FakeRepo.put(
          meta_key,
          Codec.encode(:memory_meta, %{observed_at: @too_large_score, class: :semantic, tags: [], cleanup_at: nil})
        )

      assert {:error, %Error.InvalidInputError{field: :memory_meta}} =
               MemoryStore.get({record.namespace, record.id}, storage_opts)

      FakeRepo.reset()
      :ok = FakeRepo.put(record_key, Codec.encode(:memory_record, record))

      :ok =
        FakeRepo.put(
          meta_key,
          Codec.encode(:memory_meta, %{observed_at: 1, class: :semantic, tags: [123], cleanup_at: nil})
        )

      assert {:error, %Error.InvalidInputError{field: :memory_meta}} =
               MemoryStore.get({record.namespace, record.id}, storage_opts)

      FakeRepo.reset()
      :ok = FakeRepo.put(record_key, Codec.encode(:memory_record, record))
      :ok = FakeRepo.put(meta_key, Codec.encode(:memory_meta, %{bad: :shape}))

      assert {:error, %Error.InvalidInputError{field: :memory_meta}} =
               MemoryStore.get({record.namespace, record.id}, storage_opts)
    end

    test "validates record and key inputs", %{storage_opts: storage_opts} do
      record = memory_record(%{id: unique_id("invalid-record")})
      {:ok, options} = MemoryOptions.validate(storage_opts)

      assert {:error, %Error.InvalidInputError{field: :memory_record}} = MemoryStore.put(:not_a_record, storage_opts)
      assert {:error, %Error.InvalidInputError{field: :memory_key}} = MemoryStore.get(:not_a_key, storage_opts)
      assert {:error, %Error.InvalidInputError{field: :memory_key}} = MemoryStore.delete(:not_a_key, storage_opts)
      assert {:error, %Error.InvalidInputError{field: :memory_record}} = MemoryRecords.put(:not_a_record, options)
      assert {:error, %Error.InvalidInputError{field: :memory_key}} = MemoryRecords.get("", record.id, options)

      for bad_record <- [
            %{record | namespace: ""},
            %{record | id: ""},
            %{record | observed_at: @too_large_score},
            %{record | expires_at: @too_large_score},
            %{record | tags: [123]},
            %{record | tags: "not-a-list"},
            %{record | metadata: :bad}
          ] do
        assert {:error, %Error.InvalidInputError{field: :memory_record}} = MemoryStore.put(bad_record, storage_opts)
      end
    end

    test "expires records by record expires_at and prunes indexes", %{storage_opts: storage_opts} do
      now = System.system_time(:millisecond)
      expired = memory_record(%{id: unique_id("expired"), text: "expired", expires_at: now - 10})
      fresh = memory_record(%{id: unique_id("fresh"), text: "fresh", expires_at: now + 60_000})

      assert {:ok, ^expired} = MemoryStore.put(expired, storage_opts)
      assert {:ok, ^fresh} = MemoryStore.put(fresh, storage_opts)

      assert {:ok, 1} = MemoryStore.prune_expired(storage_opts)
      assert :not_found = MemoryStore.get({expired.namespace, expired.id}, storage_opts)
      assert {:ok, ^fresh} = MemoryStore.get({fresh.namespace, fresh.id}, storage_opts)
    end

    test "honors store-level ttl at read time", %{storage_opts: storage_opts} do
      opts = Keyword.put(storage_opts, :ttl, 1)
      record = memory_record(%{id: unique_id("ttl"), text: "short lived"})

      assert {:ok, ^record} = MemoryStore.put(record, opts)
      Process.sleep(10)

      assert :not_found = MemoryStore.get({record.namespace, record.id}, opts)
    end
  end

  describe "query indexes" do
    test "queries by class tags text and time", %{storage_opts: storage_opts} do
      matching =
        memory_record(%{
          id: unique_id("match"),
          class: :semantic,
          kind: :fact,
          text: "The user prefers concise Bedrock answers.",
          tags: ["preferences", "user"],
          observed_at: 1_000
        })

      wrong_class =
        memory_record(%{
          id: unique_id("wrong-class"),
          class: :episodic,
          kind: :event,
          text: "The user prefers concise Bedrock answers.",
          tags: ["preferences", "user"],
          observed_at: 1_100
        })

      other_namespace =
        memory_record(%{
          id: unique_id("other-ns"),
          namespace: "agent:other",
          class: :semantic,
          text: "The user prefers concise Bedrock answers.",
          tags: ["preferences", "user"],
          observed_at: 1_200
        })

      assert {:ok, ^matching} = MemoryStore.put(matching, storage_opts)
      assert {:ok, ^wrong_class} = MemoryStore.put(wrong_class, storage_opts)
      assert {:ok, ^other_namespace} = MemoryStore.put(other_namespace, storage_opts)

      query =
        Query.new!(%{
          namespace: @namespace,
          classes: [:semantic],
          tags_all: ["preferences", "user"],
          text_contains: "concise bedrock",
          since: 900,
          until: 1_050,
          order: :asc
        })

      assert {:ok, [^matching]} = MemoryStore.query(query, storage_opts)
    end

    test "upserts deindex previous class and tag entries", %{storage_opts: storage_opts} do
      id = unique_id("upsert")

      old =
        memory_record(%{
          id: id,
          class: :episodic,
          text: "old memory",
          tags: ["old"],
          observed_at: 100
        })

      new =
        memory_record(%{
          id: id,
          class: :semantic,
          text: "new memory",
          tags: ["new"],
          observed_at: 200
        })

      assert {:ok, ^old} = MemoryStore.put(old, storage_opts)
      assert {:ok, ^new} = MemoryStore.put(new, storage_opts)

      assert {:ok, []} = MemoryStore.query(Query.new!(%{namespace: @namespace, tags_any: ["old"]}), storage_opts)
      assert {:ok, [^new]} = MemoryStore.query(Query.new!(%{namespace: @namespace, tags_any: ["new"]}), storage_opts)
      assert {:ok, [^new]} = MemoryStore.query(Query.new!(%{namespace: @namespace, classes: [:semantic]}), storage_opts)
    end

    test "handles missing indexed records and content/kind matching", %{storage_opts: storage_opts} do
      missing_id = unique_id("missing-index")
      missing_index_key = MemoryKeys.namespace_time_key(storage_opts[:prefix], @namespace, 1, missing_id)

      :ok = FakeRepo.put(missing_index_key, Codec.encode(:memory_index, %{namespace: @namespace, id: missing_id}))

      content_record =
        memory_record(%{
          id: unique_id("content-kind"),
          kind: "profile",
          text: nil,
          content: %{note: "needle in structured content"},
          observed_at: 2
        })

      assert {:ok, ^content_record} = MemoryStore.put(content_record, storage_opts)

      assert {:ok, [^content_record]} =
               MemoryStore.query(
                 Query.new!(%{namespace: @namespace, kinds: ["profile"], text_contains: "needle"}),
                 storage_opts
               )
    end

    test "returns corruption errors for malformed index values", %{storage_opts: storage_opts} do
      query = Query.new!(%{namespace: @namespace})
      index_key = MemoryKeys.namespace_time_key(storage_opts[:prefix], @namespace, 1, unique_id("corrupt-index"))

      :ok = FakeRepo.put(index_key, :erlang.term_to_binary(%{namespace: @namespace, id: "bad"}))

      assert {:error, %Error.InvalidInputError{field: :envelope}} = MemoryStore.query(query, storage_opts)

      FakeRepo.reset()
      :ok = FakeRepo.put(index_key, Codec.encode(:memory_index, %{namespace: @namespace}))

      assert {:error, %Error.InvalidInputError{field: :memory_index}} = MemoryStore.query(query, storage_opts)
    end

    test "validates query inputs", %{storage_opts: storage_opts} do
      {:ok, options} = MemoryOptions.validate(storage_opts)
      query = Query.new!(%{namespace: @namespace})

      assert {:error, :namespace_required} = MemoryStore.query(Query.new!(%{}), storage_opts)
      assert {:error, :namespace_required} = MemoryRecords.query(%{namespace: nil}, options)
      assert {:error, %Error.InvalidInputError{field: :memory_query}} = MemoryStore.query(:not_a_query, storage_opts)

      assert {:error, %Error.InvalidInputError{field: :memory_query}} =
               MemoryRecords.query(%{query | since: @too_large_score}, options)

      assert {:error, %Error.InvalidInputError{field: :memory_query}} =
               MemoryRecords.query(%{query | until: @too_large_score}, options)

      assert {:error, %Error.InvalidInputError{field: :memory_query}} =
               MemoryRecords.query(%{query | tags_any: [123]}, options)

      assert {:error, %Error.InvalidInputError{field: :memory_query}} =
               MemoryRecords.query(%{query | text_contains: 123}, options)

      assert {:error, %Error.InvalidInputError{field: :memory_query}} =
               MemoryRecords.query(%{query | namespace: ""}, options)
    end

    test "uses existing record fallback when metadata is missing", %{storage_opts: storage_opts} do
      existing = memory_record(%{id: unique_id("missing-meta-existing"), text: "existing", tags: ["old"]})
      replacement = %{existing | text: "replacement", tags: ["new"], observed_at: existing.observed_at + 1}
      record_key = MemoryKeys.record_key(storage_opts[:prefix], existing.namespace, existing.id)

      :ok = FakeRepo.put(record_key, Codec.encode(:memory_record, existing))

      assert {:ok, ^replacement} = MemoryStore.put(replacement, storage_opts)

      assert {:ok, [^replacement]} =
               MemoryStore.query(Query.new!(%{namespace: @namespace, tags_any: ["new"]}), storage_opts)
    end

    test "rejects existing raw records when metadata fallback would be needed", %{storage_opts: storage_opts} do
      existing = memory_record(%{id: unique_id("bad-existing")})
      record_key = MemoryKeys.record_key(storage_opts[:prefix], existing.namespace, existing.id)

      :ok = FakeRepo.put(record_key, :erlang.term_to_binary(existing))

      assert {:error, %Error.InvalidInputError{field: :envelope}} =
               MemoryStore.put(%{existing | text: "replacement"}, storage_opts)
    end
  end

  describe "expiration edge cases" do
    test "expires records from record expires_at when metadata is missing", %{storage_opts: storage_opts} do
      record =
        memory_record(%{id: unique_id("metadata-missing-expired"), expires_at: System.system_time(:millisecond) - 1})

      record_key = MemoryKeys.record_key(storage_opts[:prefix], record.namespace, record.id)

      :ok = FakeRepo.put(record_key, Codec.encode(:memory_record, record))

      assert :not_found = MemoryStore.get({record.namespace, record.id}, storage_opts)
    end

    test "prune clears stale expiry index entries without deleting fresh records", %{storage_opts: storage_opts} do
      now = System.system_time(:millisecond)
      record = memory_record(%{id: unique_id("stale-expiry"), expires_at: now + 60_000})
      stale_expiry_key = MemoryKeys.expires_key(storage_opts[:prefix], now - 1, record.namespace, record.id)

      assert {:ok, ^record} = MemoryStore.put(record, storage_opts)
      :ok = FakeRepo.put(stale_expiry_key, Codec.encode(:memory_index, %{namespace: record.namespace, id: record.id}))

      assert {:ok, 0} = MemoryStore.prune_expired(storage_opts)
      assert is_nil(FakeRepo.get(stale_expiry_key))
      assert {:ok, ^record} = MemoryStore.get({record.namespace, record.id}, storage_opts)
    end

    test "prune returns corruption errors for bad expiry metadata", %{storage_opts: storage_opts} do
      now = System.system_time(:millisecond)
      record = memory_record(%{id: unique_id("bad-expiry-meta"), expires_at: now - 1})
      record_key = MemoryKeys.record_key(storage_opts[:prefix], record.namespace, record.id)
      meta_key = MemoryKeys.meta_key(storage_opts[:prefix], record.namespace, record.id)
      expiry_key = MemoryKeys.expires_key(storage_opts[:prefix], now - 1, record.namespace, record.id)

      :ok = FakeRepo.put(record_key, Codec.encode(:memory_record, record))
      :ok = FakeRepo.put(meta_key, Codec.encode(:memory_meta, %{bad: :shape}))
      :ok = FakeRepo.put(expiry_key, Codec.encode(:memory_index, %{namespace: record.namespace, id: record.id}))

      assert {:error, %Error.InvalidInputError{field: :memory_meta}} = MemoryStore.prune_expired(storage_opts)
    end
  end

  describe "jido_memory integration" do
    test "works through BasicPlugin and Runtime", %{storage_opts: storage_opts} do
      store = {MemoryStore, storage_opts}

      assert {:ok, plugin_state} =
               Jido.Memory.BasicPlugin.mount(%{id: "bedrock-agent"}, %{store: store, auto_capture: false})

      agent = %{id: "bedrock-agent", __memory__: plugin_state}

      assert {:ok, %Record{id: id}} =
               Runtime.remember(agent, %{
                 class: :semantic,
                 kind: :fact,
                 text: "Bedrock is the durable memory store.",
                 tags: ["bedrock"]
               })

      assert {:ok, %RetrieveResult{hits: [hit]}} =
               Runtime.retrieve(agent, %{text_contains: "durable memory", order: :asc})

      assert hit.record.id == id
      assert {:ok, true} = Runtime.forget(agent, id)
      assert {:error, :not_found} = Runtime.get(agent, id)
    end

    test "emits telemetry for memory operations", %{storage_opts: storage_opts} do
      test_pid = self()
      handler_id = "jido-bedrock-memory-store-#{System.unique_integer([:positive])}"
      event = [:jido_bedrock, :storage, :memory_put, :stop]

      :ok =
        :telemetry.attach(
          handler_id,
          event,
          fn ^event, measurements, metadata, _config ->
            send(test_pid, {:memory_telemetry, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      record = memory_record(%{id: unique_id("telemetry"), text: "telemetry"})
      assert {:ok, ^record} = MemoryStore.put(record, storage_opts)
      assert_receive {:memory_telemetry, %{duration: duration}, %{operation: :memory_put, status: :ok}}
      assert is_integer(duration)
    end
  end

  defp memory_record(attrs) do
    defaults = %{
      id: unique_id("memory"),
      namespace: @namespace,
      class: :semantic,
      kind: :fact,
      text: "memory",
      content: %{},
      tags: [],
      observed_at: System.system_time(:millisecond),
      metadata: %{}
    }

    attrs
    |> Map.new()
    |> then(&Map.merge(defaults, &1))
    |> Record.new!()
  end
end
