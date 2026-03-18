defmodule Expert.Logging.ProjectLogFileTest do
  use ExUnit.Case, async: false

  alias Expert.Logging.ProjectLogFile

  require Logger

  @handler_name :expert_project_log

  setup do
    temp_root =
      System.tmp_dir!()
      |> Path.join("expert-log-test-#{System.unique_integer([:positive])}")
      |> tap(&File.mkdir_p!/1)

    on_exit(fn ->
      case :logger.remove_handler(@handler_name) do
        :ok -> :ok
        {:error, {:not_found, @handler_name}} -> :ok
      end

      File.rm_rf!(temp_root)
    end)

    %{temp_root: temp_root}
  end

  test "attach/1 creates .expert, .gitignore and expert.log", %{temp_root: temp_root} do
    log_path = Path.join([temp_root, ".expert", "expert.log"])
    gitignore_path = Path.join([temp_root, ".expert", ".gitignore"])

    assert :ok = ProjectLogFile.attach(temp_root)

    Logger.info("project log file test")
    Logger.flush()

    assert File.dir?(Path.join(temp_root, ".expert"))
    assert File.read!(gitignore_path) == "*\n"
    assert File.regular?(log_path)
  end
end
