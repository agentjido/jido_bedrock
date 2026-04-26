defmodule Jido.Bedrock.StorageHardeningTest do
  use Jido.Bedrock.Case, async: false

  alias Jido.Bedrock.Error
  alias Jido.Bedrock.Storage.Codec
  alias Jido.Bedrock.Storage.Keys
  alias Jido.Bedrock.Storage.Telemetry
  alias Jido.Bedrock.Storage.Transaction
  alias Jido.Thread.Entry

  defmodule ErrorRepo do
    @moduledoc false
    def transact(_fun), do: {:error, :repo_down}
  end

  defmodule RaisingRepo do
    @moduledoc false
    def transact(_fun), do: raise("repo exploded")
  end

  defmodule PassthroughRepo do
    @moduledoc false
    def transact(fun), do: fun.()
  end

  defmodule NoRollbackRepo do
    @moduledoc false
  end

  describe "codec envelopes" do
    test "round trips versioned envelopes" do
      data = %{state: %{counter: 1}}

      assert {:ok, ^data} =
               :checkpoint
               |> Codec.encode(data)
               |> Codec.decode(:checkpoint)
    end

    test "rejects legacy raw terms" do
      legacy = :erlang.term_to_binary(%{state: %{counter: 1}})

      assert {:error, %Error.InvalidInputError{} = error} = Codec.decode(legacy, :checkpoint)
      assert error.field == :envelope
    end

    test "rejects unsupported versions and wrong envelope types" do
      unsupported = :erlang.term_to_binary(%{version: 2, type: :checkpoint, data: %{}})
      wrong_type = Codec.encode(:thread_meta, %{rev: 0, created_at: 1, updated_at: 1, metadata: %{}})

      assert {:error, %Error.InvalidInputError{field: :version}} = Codec.decode(unsupported, :checkpoint)
      assert {:error, %Error.InvalidInputError{field: :type}} = Codec.decode(wrong_type, :checkpoint)
    end

    test "rejects invalid binaries" do
      assert {:error, %Error.InvalidInputError{} = error} = Codec.decode(<<0, 1, 2>>, :checkpoint)
      assert error.field == :value
    end

    test "exposes envelope helpers and rejects non-binary values" do
      assert Codec.version() == 1
      assert Codec.envelope(:checkpoint, :data) == %{version: 1, type: :checkpoint, data: :data}

      assert {:error, %Error.InvalidInputError{field: :value}} = Codec.decode(:not_binary, :checkpoint)
    end
  end

  describe "option validation" do
    test "returns config errors for missing or invalid repo" do
      assert {:error, %Error.ConfigError{key: :repo, value: nil}} = Storage.get_checkpoint(:key, [])
      assert {:error, %Error.ConfigError{key: :repo, value: 123}} = Storage.get_checkpoint(:key, repo: 123)
      assert {:error, %Error.ConfigError{key: :repo}} = Storage.get_checkpoint(:key, repo: Missing.Repo.Module)
    end

    test "returns config errors for invalid prefixes", %{storage_opts: storage_opts} do
      assert {:error, %Error.ConfigError{key: :prefix}} =
               Storage.get_checkpoint(:key, Keyword.put(storage_opts, :prefix, "missing-slash"))

      assert {:error, %Error.ConfigError{key: :prefix}} =
               Storage.get_checkpoint(:key, Keyword.put(storage_opts, :prefix, ""))

      assert {:error, %Error.ConfigError{key: :prefix}} =
               Storage.get_checkpoint(:key, Keyword.put(storage_opts, :prefix, :not_binary))
    end

    test "returns invalid errors for append-only option problems", %{storage_opts: storage_opts} do
      assert {:error, %Error.InvalidInputError{field: :expected_rev}} =
               Storage.append_thread("thread", [%{kind: :note}], Keyword.put(storage_opts, :expected_rev, -1))

      assert {:error, %Error.InvalidInputError{field: :metadata}} =
               Storage.append_thread("thread", [%{kind: :note}], Keyword.put(storage_opts, :metadata, :bad))
    end

    test "returns invalid errors for bad thread ids and entries", %{storage_opts: storage_opts} do
      assert {:error, %Error.InvalidInputError{field: :thread_id}} =
               Storage.load_thread("", storage_opts)

      assert {:error, %Error.InvalidInputError{field: :entries}} =
               Storage.append_thread("thread", [:not_an_entry], storage_opts)

      assert {:error, %Error.ConfigError{key: :opts}} = Storage.get_checkpoint(:key, :not_options)
    end
  end

  describe "thread corruption detection" do
    test "detects missing entries for metadata revision", %{storage_opts: storage_opts} do
      thread_id = unique_id("missing-entry")
      write_meta(storage_opts, thread_id, %{rev: 1, created_at: 1, updated_at: 1, metadata: %{}})

      assert {:error, %Error.InvalidInputError{} = error} = Storage.load_thread(thread_id, storage_opts)
      assert error.message =~ "entry count"
    end

    test "detects non-contiguous stored entry sequence numbers", %{storage_opts: storage_opts} do
      thread_id = unique_id("gap-entry")
      write_meta(storage_opts, thread_id, %{rev: 2, created_at: 1, updated_at: 1, metadata: %{}})
      write_entry(storage_opts, thread_id, entry(0))
      write_entry(storage_opts, thread_id, entry(2))

      assert {:error, %Error.InvalidInputError{} = error} = Storage.load_thread(thread_id, storage_opts)
      assert error.message =~ "contiguous"
    end

    test "detects invalid thread metadata and entry shapes", %{storage_opts: storage_opts} do
      bad_meta_thread = unique_id("bad-meta")
      bad_entry_thread = unique_id("bad-entry")
      bad_timestamp_thread = unique_id("bad-timestamp")

      raw_put(
        storage_opts,
        Keys.thread_meta_key(storage_opts[:prefix], bad_meta_thread),
        Codec.encode(:thread_meta, %{rev: -1})
      )

      write_meta(storage_opts, bad_entry_thread, %{rev: 1, created_at: 1, updated_at: 1, metadata: %{}})

      write_meta(storage_opts, bad_timestamp_thread, %{rev: 0, created_at: -1, updated_at: 1, metadata: %{}})

      raw_put(
        storage_opts,
        Keys.thread_entry_key(storage_opts[:prefix], bad_entry_thread, 0),
        Codec.encode(:thread_entry, %{not: :entry})
      )

      assert {:error, %Error.InvalidInputError{field: :thread_meta}} =
               Storage.load_thread(bad_meta_thread, storage_opts)

      assert {:error, %Error.InvalidInputError{field: :thread_entry}} =
               Storage.load_thread(bad_entry_thread, storage_opts)

      assert {:error, %Error.InvalidInputError{field: :thread_meta}} =
               Storage.load_thread(bad_timestamp_thread, storage_opts)
    end

    test "detects invalid encoded stored values", %{storage_opts: storage_opts} do
      thread_id = unique_id("bad-binary")
      raw_put(storage_opts, Keys.thread_meta_key(storage_opts[:prefix], thread_id), <<0, 1, 2>>)

      assert {:error, %Error.InvalidInputError{field: :value}} = Storage.load_thread(thread_id, storage_opts)
    end

    test "detects thread entry keys that disagree with stored entries", %{storage_opts: storage_opts} do
      mismatched_thread = unique_id("mismatched-key")
      malformed_key_thread = unique_id("malformed-key")

      write_meta(storage_opts, mismatched_thread, %{rev: 1, created_at: 1, updated_at: 1, metadata: %{}})

      raw_put(
        storage_opts,
        Keys.thread_entry_key(storage_opts[:prefix], mismatched_thread, 0),
        Codec.encode(:thread_entry, entry(1))
      )

      write_meta(storage_opts, malformed_key_thread, %{rev: 1, created_at: 1, updated_at: 1, metadata: %{}})

      raw_put(
        storage_opts,
        Keys.thread_entries_prefix(storage_opts[:prefix], malformed_key_thread) <> "bad-suffix",
        Codec.encode(:thread_entry, entry(0))
      )

      assert {:error, %Error.InvalidInputError{field: :thread_entry_key}} =
               Storage.load_thread(mismatched_thread, storage_opts)

      assert {:error, %Error.InvalidInputError{field: :thread_entry_key}} =
               Storage.load_thread(malformed_key_thread, storage_opts)
    end

    test "large corrupt revisions fail without constructing expected sequence ranges", %{storage_opts: storage_opts} do
      thread_id = unique_id("huge-rev")
      write_meta(storage_opts, thread_id, %{rev: 1_000_000_000, created_at: 1, updated_at: 1, metadata: %{}})

      assert {:error, %Error.InvalidInputError{} = error} = Storage.load_thread(thread_id, storage_opts)
      assert error.message =~ "entry count"
    end
  end

  describe "concurrency and telemetry" do
    test "only one concurrent expected_rev append wins", %{storage_opts: storage_opts} do
      thread_id = unique_id("concurrent-thread")
      assert {:ok, %{rev: 1}} = Storage.append_thread(thread_id, [%{kind: :note, payload: %{n: 0}}], storage_opts)

      results =
        1..8
        |> Task.async_stream(
          fn n ->
            Storage.append_thread(
              thread_id,
              [%{kind: :note, payload: %{n: n}}],
              Keyword.put(storage_opts, :expected_rev, 1)
            )
          end,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :conflict}, &1)) == 7
      assert {:ok, thread} = Storage.load_thread(thread_id, storage_opts)
      assert thread.rev == 2
    end

    test "emits telemetry for storage operations", %{storage_opts: storage_opts} do
      test_pid = self()
      handler_id = "jido-bedrock-storage-hardening-#{System.unique_integer([:positive])}"
      event = [:jido_bedrock, :storage, :checkpoint_put, :stop]

      :ok =
        :telemetry.attach(
          handler_id,
          event,
          fn ^event, measurements, metadata, _config ->
            send(test_pid, {:telemetry_event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = Storage.put_checkpoint({:agent, unique_id("telemetry")}, %{state: %{}}, storage_opts)
      assert_receive {:telemetry_event, %{duration: duration}, %{operation: :checkpoint_put, status: :ok}}
      assert is_integer(duration)
    end

    test "emits exception telemetry for raises and throws" do
      assert_raise RuntimeError, fn ->
        Telemetry.span(:test_raise, %{}, fn -> raise "boom" end)
      end

      assert catch_throw(Telemetry.span(:test_throw, %{}, fn -> throw(:boom) end)) == :boom
      assert Telemetry.span(:test_status, %{}, fn -> :custom end) == :custom
      assert :ok = Telemetry.emit(:test_emit, :custom)
    end
  end

  describe "transaction and error branches" do
    test "wraps repo transaction failures in execution errors" do
      assert {:error, %Error.ExecutionFailureError{} = error} =
               Transaction.run(ErrorRepo, :test_operation, fn -> :ok end)

      assert error.reason == :repo_down
      assert error.operation == :test_operation
    end

    test "wraps unexpected repo raises in internal errors" do
      assert {:error, %Error.InternalError{} = error} =
               Transaction.run(RaisingRepo, :test_operation, fn -> :ok end)

      assert %RuntimeError{} = error.reason
    end

    test "preserves conflicts and wraps non-conflict rollbacks" do
      assert {:error, :conflict} =
               Transaction.run(PassthroughRepo, :test_operation, fn ->
                 throw({__MODULE__, :rollback, :conflict})
               end)

      assert {:error, %Error.ExecutionFailureError{} = error} =
               Transaction.run(PassthroughRepo, :test_operation, fn ->
                 throw({__MODULE__, :rollback, :other})
               end)

      assert error.reason == :other
    end

    test "wraps rollback requests when repo rollback is unavailable" do
      assert {:error, %Error.ExecutionFailureError{} = error} =
               Transaction.run(PassthroughRepo, :test_operation, fn ->
                 Transaction.rollback(NoRollbackRepo, :cannot_rollback)
               end)

      assert error.reason == :cannot_rollback
    end

    test "wraps unexpected nonlocal exits in internal errors" do
      assert {:error, %Error.InternalError{} = error} =
               Transaction.run(PassthroughRepo, :test_operation, fn -> throw(:unexpected_throw) end)

      assert error.reason == {:throw, :unexpected_throw}
    end

    test "constructs Splode error defaults and map opts" do
      assert %Error.InvalidInputError{message: "Invalid input"} = Error.InvalidInputError.exception([])
      assert %Error.ConfigError{message: "Invalid configuration"} = Error.ConfigError.exception([])
      assert %Error.ExecutionFailureError{message: "Execution failed"} = Error.ExecutionFailureError.exception([])
      assert %Error.InternalError{message: "Internal error"} = Error.InternalError.exception([])

      assert %Error.InternalError{reason: :boom} = Error.internal_error("internal", %{reason: :boom})
      assert %Error.Internal.UnknownError{message: "Unknown internal error"} = Error.Internal.UnknownError.exception([])
      assert %Error.Internal.UnknownError{message: "text"} = Error.Internal.UnknownError.exception(error: "text")
      assert %Error.Internal.UnknownError{message: ":atom"} = Error.Internal.UnknownError.exception(error: :atom)
    end
  end

  defp write_meta(storage_opts, thread_id, meta) do
    raw_put(storage_opts, Keys.thread_meta_key(storage_opts[:prefix], thread_id), Codec.encode(:thread_meta, meta))
  end

  defp write_entry(storage_opts, thread_id, %Entry{seq: seq} = entry) do
    raw_put(
      storage_opts,
      Keys.thread_entry_key(storage_opts[:prefix], thread_id, seq),
      Codec.encode(:thread_entry, entry)
    )
  end

  defp raw_put(storage_opts, key, value) do
    :ok = storage_opts[:repo].put(key, value)
  end

  defp entry(seq) do
    %Entry{id: "entry-#{seq}", seq: seq, at: 1, kind: :note, payload: %{seq: seq}, refs: %{}}
  end
end
