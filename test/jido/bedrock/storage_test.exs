defmodule Jido.Bedrock.StorageTest do
  use Jido.Bedrock.Case, async: false

  test "checkpoint operations", %{storage_opts: storage_opts} do
    key = {:agent, unique_id("checkpoint")}
    data = %{state: %{a: 1}}

    assert :not_found = Storage.get_checkpoint(key, storage_opts)
    assert :ok = Storage.put_checkpoint(key, data, storage_opts)
    assert {:ok, ^data} = Storage.get_checkpoint(key, storage_opts)
    assert :ok = Storage.delete_checkpoint(key, storage_opts)
    assert :not_found = Storage.get_checkpoint(key, storage_opts)
  end

  test "expected_rev conflict", %{storage_opts: storage_opts} do
    thread_id = unique_id("conflict-thread")

    assert {:ok, first} =
             Storage.append_thread(
               thread_id,
               [%{kind: :note, payload: %{n: 1}}],
               Keyword.put(storage_opts, :expected_rev, 0)
             )

    assert first.rev == 1

    assert {:error, :conflict} =
             Storage.append_thread(
               thread_id,
               [%{kind: :note, payload: %{n: 2}}],
               Keyword.put(storage_opts, :expected_rev, 0)
             )
  end

  test "load_thread reconstructs entries written under a shared prefix", %{storage_opts: storage_opts} do
    thread_id = unique_id("shared-prefix-thread")

    assert {:ok, appended} =
             Storage.append_thread(
               thread_id,
               [
                 %{kind: :note, payload: %{n: 1}},
                 %{kind: :note, payload: %{n: 2}}
               ],
               storage_opts
             )

    assert appended.rev == 2

    assert {:ok, loaded} = Storage.load_thread(thread_id, storage_opts)
    assert loaded.rev == 2
    assert Enum.map(loaded.entries, & &1.payload.n) == [1, 2]
  end

  test "delete_thread clears meta and entry keys", %{storage_opts: storage_opts} do
    thread_id = unique_id("delete-thread")

    assert {:ok, _thread} =
             Storage.append_thread(
               thread_id,
               [
                 %{kind: :note, payload: %{n: 1}},
                 %{kind: :note, payload: %{n: 2}}
               ],
               storage_opts
             )

    assert :ok = Storage.delete_thread(thread_id, storage_opts)
    assert :not_found = Storage.load_thread(thread_id, storage_opts)
  end
end
