defmodule Forge.LogFilter do
  def hook_into_logger do
    :logger.add_primary_filter(:ignore_module_warnings, {&reject_module_warnings/2, []})
  end

  def reject_module_warnings(log_event, _) do
    case log_event do
      %{msg: {:report, _}} ->
        :ignore

      %{msg: {:string, message}} ->
        message
        |> ensure_binary()
        |> action()

      %{msg: {format_string, format_data}} ->
        {:ok, pid} = StringIO.open("log")

        :io.format(pid, format_string, format_data)

        pid
        |> StringIO.flush()
        |> ensure_binary()
        |> tap(fn _ -> StringIO.close(pid) end)
        |> action()

      _ ->
        :ignore
    end
  end

  defp action(message) do
    if message =~ "is already compiled." do
      :stop
    else
      :ignore
    end
  end

  defp ensure_binary(charlist) when is_list(charlist) do
    List.to_string(charlist)
  end

  defp ensure_binary(s) when is_binary(s) do
    s
  end
end
