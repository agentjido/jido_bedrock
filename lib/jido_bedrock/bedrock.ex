defmodule Jido.Bedrock do
  @moduledoc """
  Bedrock integrations for Jido runtimes.

  This package provides Bedrock-backed adapters that plug into Jido storage,
  lifecycle, and memory APIs.
  """

  @doc "Returns the default storage adapter module for Jido persistence."
  @spec storage_adapter() :: module()
  def storage_adapter, do: Jido.Bedrock.Storage

  @doc "Returns the Bedrock-backed store adapter module for jido_memory."
  @spec memory_store_adapter() :: module()
  def memory_store_adapter, do: Jido.Bedrock.Memory.Store
end
