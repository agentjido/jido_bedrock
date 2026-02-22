defmodule JidoBedrockTest do
  use ExUnit.Case, async: true

  test "exports Jido.Bedrock storage adapter" do
    assert Jido.Bedrock.storage_adapter() == Jido.Bedrock.Storage
    assert JidoBedrock.storage_adapter() == Jido.Bedrock.Storage
  end
end
