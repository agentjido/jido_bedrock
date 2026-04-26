defmodule Jido.Bedrock.Storage.Telemetry do
  @moduledoc false

  @prefix [:jido_bedrock, :storage]

  @doc false
  @spec span(atom(), map(), (-> result)) :: result when result: term()
  def span(operation, metadata, fun) when is_atom(operation) and is_map(metadata) and is_function(fun, 0) do
    start_time = System.monotonic_time(:nanosecond)
    metadata = Map.put_new(metadata, :operation, operation)

    :telemetry.execute(@prefix ++ [operation, :start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()
      duration = System.monotonic_time(:nanosecond) - start_time

      :telemetry.execute(
        @prefix ++ [operation, :stop],
        %{duration: duration},
        Map.put(metadata, :status, status(result))
      )

      result
    rescue
      error ->
        duration = System.monotonic_time(:nanosecond) - start_time

        :telemetry.execute(
          @prefix ++ [operation, :exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: :error, reason: error, stacktrace: __STACKTRACE__})
        )

        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        duration = System.monotonic_time(:nanosecond) - start_time

        :telemetry.execute(
          @prefix ++ [operation, :exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc false
  @spec emit(atom(), atom(), map(), map()) :: :ok
  def emit(operation, event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(@prefix ++ [operation, event], measurements, Map.put_new(metadata, :operation, operation))
  end

  defp status(:ok), do: :ok
  defp status(:not_found), do: :not_found
  defp status({:ok, _result}), do: :ok
  defp status({:error, :conflict}), do: :conflict
  defp status({:error, _reason}), do: :error
  defp status(_result), do: :ok
end
