defmodule Expert.Logging.ProjectLogFile do
  @moduledoc false

  @max_no_bytes 10_485_760
  @max_no_files 3

  def handler_name do
    :expert_project_log
  end

  def attach(root_path \\ File.cwd!()) when is_binary(root_path) do
    with :ok <- ensure_workspace(root_path) do
      add_handler(log_config(root_path))
    end
  end

  defp ensure_workspace(root_path) do
    workspace_path = Path.join(root_path, ".expert")
    gitignore_path = Path.join(workspace_path, ".gitignore")

    with :ok <- File.mkdir_p(workspace_path) do
      ensure_gitignore(gitignore_path)
    end
  end

  defp ensure_gitignore(path) do
    if File.exists?(path) do
      :ok
    else
      File.write(path, "*\n")
    end
  end

  defp add_handler(config) do
    handler_name()
    |> :logger.add_handler(:logger_std_h, config)
  end

  defp log_config(root_path) do
    log_file_name =
      root_path
      |> Path.join(".expert")
      |> Path.join("expert.log")
      |> String.to_charlist()

    %{
      config: %{
        file: log_file_name,
        max_no_bytes: @max_no_bytes,
        max_no_files: @max_no_files
      },
      formatter: Logger.Formatter.new(metadata: [:instance_id]),
      level: :debug
    }
  end
end
