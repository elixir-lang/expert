defmodule Expert.Logging.ProjectLogFileTest do
  use ExUnit.Case, async: false

  alias Expert.Logging.ProjectLogFile

  require Logger

  setup do
    on_exit(fn ->
      ProjectLogFile.handler_name()
      |> :logger.remove_handler()
    end)
  end

  @tag :tmp_dir
  test "attach/1 creates .expert, .gitignore and expert.log", %{tmp_dir: tmp_dir} do
    log_path = Path.join([tmp_dir, ".expert", "expert.log"])
    gitignore_path = Path.join([tmp_dir, ".expert", ".gitignore"])

    assert :ok = ProjectLogFile.attach(tmp_dir)

    Logger.info("project log file test")
    Logger.flush()

    assert File.dir?(Path.join(tmp_dir, ".expert"))
    assert File.read!(gitignore_path) == "*\n"
    assert File.regular?(log_path)
  end
end
