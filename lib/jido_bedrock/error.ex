defmodule Jido.Bedrock.Error do
  @moduledoc """
  Centralized error handling for `jido_bedrock` using Splode.
  """

  use Splode,
    error_classes: [
      invalid: Invalid,
      execution: Execution,
      config: Config,
      internal: Internal
    ],
    unknown_error: __MODULE__.Internal.UnknownError

  defmodule Invalid do
    @moduledoc "Invalid input error class for Splode."
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Execution do
    @moduledoc "Execution error class for Splode."
    use Splode.ErrorClass, class: :execution
  end

  defmodule Config do
    @moduledoc "Configuration error class for Splode."
    use Splode.ErrorClass, class: :config
  end

  defmodule Internal do
    @moduledoc "Internal error class for Splode."
    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
      @moduledoc false
      use Splode.Error, class: :internal, fields: [:message, :error, :details]

      @type t :: %__MODULE__{
              message: String.t(),
              error: term(),
              details: map()
            }

      @impl true
      def exception(opts) do
        opts = normalize_opts(opts)
        error = Keyword.get(opts, :error)

        opts
        |> Keyword.put_new(:message, unknown_message(error))
        |> Keyword.put_new(:details, %{})
        |> super()
      end

      defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
      defp normalize_opts(opts), do: opts

      defp unknown_message(nil), do: "Unknown internal error"
      defp unknown_message(message) when is_binary(message), do: message
      defp unknown_message(error), do: inspect(error)
    end
  end

  defmodule InvalidInputError do
    @moduledoc "Error for invalid input parameters."
    use Splode.Error, class: :invalid, fields: [:message, :field, :value, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            field: atom() | nil,
            value: term(),
            details: map()
          }

    @impl true
    def exception(opts) do
      opts
      |> normalize_opts()
      |> Keyword.put_new(:message, "Invalid input")
      |> Keyword.put_new(:details, %{})
      |> super()
    end

    defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
    defp normalize_opts(opts), do: opts
  end

  defmodule ConfigError do
    @moduledoc "Error for invalid or missing package configuration."
    use Splode.Error, class: :config, fields: [:message, :key, :value, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            key: atom() | nil,
            value: term(),
            details: map()
          }

    @impl true
    def exception(opts) do
      opts
      |> normalize_opts()
      |> Keyword.put_new(:message, "Invalid configuration")
      |> Keyword.put_new(:details, %{})
      |> super()
    end

    defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
    defp normalize_opts(opts), do: opts
  end

  defmodule ExecutionFailureError do
    @moduledoc "Error for runtime execution failures."
    use Splode.Error, class: :execution, fields: [:message, :operation, :reason, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            operation: atom() | nil,
            reason: term(),
            details: map()
          }

    @impl true
    def exception(opts) do
      opts
      |> normalize_opts()
      |> Keyword.put_new(:message, "Execution failed")
      |> Keyword.put_new(:details, %{})
      |> super()
    end

    defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
    defp normalize_opts(opts), do: opts
  end

  defmodule InternalError do
    @moduledoc "Error for unexpected internal failures."
    use Splode.Error, class: :internal, fields: [:message, :reason, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            reason: term(),
            details: map()
          }

    @impl true
    def exception(opts) do
      opts
      |> normalize_opts()
      |> Keyword.put_new(:message, "Internal error")
      |> Keyword.put_new(:details, %{})
      |> super()
    end

    defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
    defp normalize_opts(opts), do: opts
  end

  @doc "Builds an invalid-input exception with optional details."
  @spec validation_error(String.t(), map() | keyword()) :: InvalidInputError.t()
  def validation_error(message, details \\ %{}) when is_binary(message) do
    details = normalize_details(details)
    InvalidInputError.exception(Keyword.merge([message: message], details))
  end

  @doc "Builds a configuration exception with optional details."
  @spec config_error(String.t(), map() | keyword()) :: ConfigError.t()
  def config_error(message, details \\ %{}) when is_binary(message) do
    details = normalize_details(details)
    ConfigError.exception(Keyword.merge([message: message], details))
  end

  @doc "Builds an execution exception with optional details."
  @spec execution_error(String.t(), map() | keyword()) :: ExecutionFailureError.t()
  def execution_error(message, details \\ %{}) when is_binary(message) do
    details = normalize_details(details)

    [message: message]
    |> Keyword.merge(details)
    |> Keyword.put_new(:details, Map.new(details))
    |> ExecutionFailureError.exception()
  end

  @doc "Builds an internal exception with optional details."
  @spec internal_error(String.t(), map() | keyword()) :: InternalError.t()
  def internal_error(message, details \\ %{}) when is_binary(message) do
    details = normalize_details(details)
    InternalError.exception(Keyword.merge([message: message], details))
  end

  defp normalize_details(details) when is_map(details), do: Map.to_list(details)
  defp normalize_details(details) when is_list(details), do: details
end
