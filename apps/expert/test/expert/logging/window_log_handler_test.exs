defmodule Expert.Logging.WindowLogHandlerTest do
  use ExUnit.Case, async: false

  alias Expert.Logging.WindowLogHandler

  defmodule OtherHandler do
    @behaviour :logger_handler

    @impl true
    def log(_event, config), do: {:ok, config}
  end

  setup do
    on_exit(fn ->
      WindowLogHandler.attach()
    end)
  end

  test "attach/0 is idempotent and keeps the runtime handler module" do
    assert :ok = WindowLogHandler.attach()
    assert :ok = WindowLogHandler.attach()

    assert {:ok, %{module: WindowLogHandler}} =
             :logger.get_handler_config(:window_log_handler)
  end

  test "attach/0 replaces an existing handler using a different module" do
    remove_window_handler()
    assert :ok = :logger.add_handler(:window_log_handler, OtherHandler, %{})
    assert {:ok, %{module: OtherHandler}} = :logger.get_handler_config(:window_log_handler)

    assert :ok = WindowLogHandler.attach()

    assert {:ok, %{module: WindowLogHandler}} =
             :logger.get_handler_config(:window_log_handler)
  end

  defp remove_window_handler do
    case :logger.remove_handler(:window_log_handler) do
      :ok -> :ok
      {:error, {:not_found, :window_log_handler}} -> :ok
    end
  end
end
