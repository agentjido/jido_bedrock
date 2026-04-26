defmodule Jido.Bedrock.Storage.Transaction do
  @moduledoc false

  alias Jido.Bedrock.Error

  @doc false
  @spec run(module(), atom(), (-> result)) :: {:ok, result} | {:error, term()} when result: term()
  def run(repo, operation, fun) when is_atom(repo) and is_atom(operation) and is_function(fun, 0) do
    try do
      case repo.transact(fun) do
        {:error, :conflict} ->
          {:error, :conflict}

        {:error, reason} when is_exception(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error,
           Error.execution_error("Bedrock transaction failed",
             operation: operation,
             reason: reason,
             details: %{repo: repo}
           )}

        result ->
          {:ok, result}
      end
    rescue
      error ->
        {:error,
         Error.internal_error("Unexpected storage transaction failure",
           reason: error,
           details: %{repo: repo, operation: operation, stacktrace: __STACKTRACE__}
         )}
    catch
      {module, :rollback, :conflict} when is_atom(module) ->
        {:error, :conflict}

      {module, :rollback, reason} when is_atom(module) ->
        {:error,
         Error.execution_error("Bedrock transaction rolled back",
           operation: operation,
           reason: reason,
           details: %{repo: repo, rollback_module: module}
         )}

      {:rollback_unavailable, reason} ->
        {:error,
         Error.execution_error("Bedrock repo does not expose rollback/1",
           operation: operation,
           reason: reason,
           details: %{repo: repo}
         )}

      kind, reason ->
        {:error,
         Error.internal_error("Unexpected storage transaction failure",
           reason: {kind, reason},
           details: %{repo: repo, operation: operation}
         )}
    end
  end

  @doc false
  @spec rollback(module(), term()) :: no_return()
  def rollback(repo, reason) do
    if function_exported?(repo, :rollback, 1) do
      repo.rollback(reason)
    else
      throw({:rollback_unavailable, reason})
    end
  end
end
