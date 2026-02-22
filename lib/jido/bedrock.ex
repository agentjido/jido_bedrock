defmodule Jido.Bedrock do
  @moduledoc """
  Bedrock integrations for Jido runtimes.

  This package provides Bedrock-backed adapters that plug into Jido storage
  and lifecycle APIs.
  """

  @doc "Returns the default storage adapter module for Jido persistence."
  @spec storage_adapter() :: module()
  def storage_adapter, do: Jido.Bedrock.Storage
end
