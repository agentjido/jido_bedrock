defmodule JidoBedrock do
  @moduledoc """
  Backward-compatible facade for `Jido.Bedrock`.

  Prefer `Jido.Bedrock` in new code.
  """

  @doc "Returns the default storage adapter module for Jido persistence."
  @spec storage_adapter() :: module()
  defdelegate storage_adapter(), to: Jido.Bedrock
end
