defmodule Jido.Bedrock.ErrorTest do
  use ExUnit.Case, async: true

  alias Jido.Bedrock.Error

  test "validation_error/2 builds an invalid input exception" do
    error = Error.validation_error("bad input", %{field: :agent_id, value: nil, details: %{code: :missing}})

    assert %Error.InvalidInputError{} = error
    assert error.message == "bad input"
    assert error.field == :agent_id
    assert error.value == nil
    assert error.details == %{code: :missing}
  end

  test "config_error/2 builds a configuration exception" do
    error = Error.config_error("bad config", %{key: :repo, value: :missing, details: %{source: :test}})

    assert %Error.ConfigError{} = error
    assert error.message == "bad config"
    assert error.key == :repo
    assert error.value == :missing
    assert error.details == %{source: :test}
  end

  test "execution_error/2 builds an execution failure exception" do
    error = Error.execution_error("boom", %{reason: :timeout})

    assert %Error.ExecutionFailureError{} = error
    assert error.message == "boom"
    assert error.details == %{reason: :timeout}
  end
end
