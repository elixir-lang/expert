defmodule Expert.Logging.WindowLogHandler do
  @moduledoc """
  Logger handler that forwards application log events to the LSP client as
  `window/logMessage` notifications.

  The handler skips OTP/SASL domain events, report-style log payloads, and
  messages emitted while forwarding itself to avoid recursive logging loops.
  """

  alias Forge.Project
  alias GenLSP.Enumerations
  alias GenLSP.Notifications.WindowLogMessage
  alias GenLSP.Structures.LogMessageParams

  use Expert.Logging.LoggerHandler

  require Logger

  @metadata_recursion_key :expert_window_log_handler
  @excluded_log_domains [:otp, :sasl]

  @doc """
  Registers the logger handler in a release-safe way.

  We intentionally register the handler with `__MODULE__` at runtime instead of `Logger.add_handlers/1` config.
  In namespaced releases, we observed app env config retaining `Expert.Logging.WindowLogHandler` while the runtime
  module is `XPExpert.Logging.WindowLogHandler`, causing handler registration to fail.
  """
  @spec attach() :: :ok | {:error, term()}
  def attach do
    case :logger.get_handler_config(:window_log_handler) do
      {:ok, %{module: __MODULE__}} ->
        :ok

      {:ok, _other_module} ->
        :ok = :logger.remove_handler(:window_log_handler)
        add_handler()

      {:error, _} ->
        add_handler()
    end
  end

  defp add_handler do
    case :logger.add_handler(:window_log_handler, __MODULE__, %{}) do
      :ok ->
        :ok

      {:error, {:already_exist, :window_log_handler}} ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to register window log handler: #{inspect(reason)}")
        error
    end
  end

  @impl true
  def log(log_event, config) do
    maybe_notify(log_event)
    {:ok, config}
  end

  defp maybe_notify(log_event) do
    with false <- ignore_event?(log_event),
         true <- Expert.Configuration.window_log_message_enabled?(),
         %GenLSP.LSP{} = lsp <- Expert.get_lsp(),
         {:ok, message} <- extract_message(log_event) do
      params = %LogMessageParams{type: to_lsp_message_type(log_event.level), message: message}

      with_recursion_metadata(fn ->
        GenLSP.notify(lsp, %WindowLogMessage{params: params})
      end)
    else
      _ -> :ok
    end
  end

  defp ignore_event?(%{msg: {:report, _}}), do: true

  defp ignore_event?(%{meta: metadata}) when is_map(metadata) do
    Map.get(metadata, @metadata_recursion_key, false) ||
      metadata
      |> Map.get(:domain, [])
      |> List.wrap()
      |> Enum.any?(&(&1 in @excluded_log_domains))
  end

  defp ignore_event?(_), do: false

  defp with_recursion_metadata(fun) do
    old_metadata = :logger.get_process_metadata()

    current_metadata =
      case old_metadata do
        :undefined -> %{}
        metadata when is_map(metadata) -> metadata
      end

    :logger.set_process_metadata(Map.put(current_metadata, @metadata_recursion_key, true))

    try do
      fun.()
    after
      case old_metadata do
        :undefined -> :logger.unset_process_metadata()
        metadata when is_map(metadata) -> :logger.set_process_metadata(metadata)
      end
    end
  end

  defp extract_message(%{msg: {:string, message}, meta: metadata}) do
    message
    |> ensure_binary()
    |> normalize_message()
    |> maybe_prepend_project(metadata)
  end

  defp extract_message(%{msg: {format_string, format_data}, meta: metadata}) do
    {:ok, pid} = StringIO.open("window_log_handler")

    :io.format(pid, format_string, format_data)

    pid
    |> StringIO.flush()
    |> ensure_binary()
    |> tap(fn _ -> StringIO.close(pid) end)
    |> normalize_message()
    |> maybe_prepend_project(metadata)
  end

  defp extract_message(_), do: :error

  defp maybe_prepend_project(:error, _metadata), do: :error

  defp maybe_prepend_project({:ok, message}, %{project: %Project{} = project}) do
    {:ok, "[#{Project.name(project)}] #{message}"}
  end

  defp maybe_prepend_project({:ok, message}, _), do: {:ok, message}

  defp normalize_message(message) do
    case String.trim(message) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp ensure_binary(charlist) when is_list(charlist), do: List.to_string(charlist)
  defp ensure_binary(string) when is_binary(string), do: string
  defp ensure_binary(other), do: inspect(other)

  defp to_lsp_message_type(level) when level in [:debug], do: Enumerations.MessageType.log()

  defp to_lsp_message_type(level) when level in [:info, :notice],
    do: Enumerations.MessageType.info()

  defp to_lsp_message_type(:warning), do: Enumerations.MessageType.warning()
  defp to_lsp_message_type(_), do: Enumerations.MessageType.error()
end
