defmodule Expert.Port do
  @moduledoc """
  Utilities for launching ports in the context of a project.
  """

  alias Forge.Project

  require Logger

  @type open_opt ::
          {:env, list()}
          | {:cd, String.t() | charlist()}
          | {:env, [{:os.env_var_name(), :os.env_var_value()}]}
          | {:args, list()}

  @type open_opts :: [open_opt]

  @doc """
  Launches elixir in a port.

  This function takes the project's context into account and looks for the executable via calling
  `elixir_executable(project)`. Environment variables are also retrieved with that call.
  """
  @spec open_elixir(Project.t(), open_opts()) :: port() | {:error, :no_elixir, String.t()}
  def open_elixir(%Project{} = project, opts) do
    case project_executable(project, "elixir") do
      {:ok, elixir_executable, environment_variables} ->
        opts =
          opts
          |> Keyword.put_new_lazy(:cd, fn -> Project.root_path(project) end)
          |> Keyword.update(:env, environment_variables, fn env ->
            environment_variables ++ env
          end)

        open_executable(elixir_executable, opts)

      {:error, _, reason} ->
        Logger.error("Failed to find elixir executable for project: #{reason}")
        {:error, :no_elixir, reason}
    end
  end

  @doc """
  Returns the specified executable path and environment for a project.

  Returns `{:ok, executable_path, env}` where:
  - `executable_path` is a charlist path to the specified executable
  - `env` is a list of `{key, value}` tuples for the environment

  Returns `{:error, name, reason}` if no executable can be found.
  """
  @spec project_executable(Project.t(), String.t()) ::
          {:ok, charlist(), list()} | {:error, String.t(), String.t()}
  def project_executable(%Project{} = project, name) do
    case find_project_executable(project, name) do
      {:ok, _, _} = success ->
        success

      {:error, name, reason} ->
        Logger.warning(
          "Failed to find #{name} for project, falling back to packaged elixir: #{reason}"
        )

        fallback_executable(name)
    end
  end

  @doc """
  Opens a port for elixir with the given executable and environment.

  Use this when you already have the elixir path and env from `elixir_executable/1`
  and need to customize the port options.

  ## Options

    * `:args` - List of arguments to pass to the elixir executable
    * `:cd` - Working directory for the port
    * `:env` - Additional environment variables (merged with the provided env)

  """
  @spec open_elixir_with_env(charlist(), list(), open_opts()) :: port()
  def open_elixir_with_env(elixir_executable, env, opts) do
    opts =
      opts
      |> Keyword.update(:env, env, fn additional_env -> env ++ additional_env end)

    open_executable(elixir_executable, opts)
  end

  def find_project_executable(%Project{} = project, name) do
    if Forge.OS.windows?() do
      find_project_executable_windows(name)
    else
      find_project_executable_unix(project, name)
    end
  end

  defp find_project_executable_windows(name) do
    release_root =
      :code.root_dir()
      |> to_string()
      |> String.downcase()
      |> String.replace("/", "\\")

    path =
      "PATH"
      |> System.get_env("")
      |> String.split(";")
      |> Enum.reject(fn entry ->
        normalized = entry |> String.downcase() |> String.replace("/", "\\")
        String.contains?(normalized, release_root)
      end)
      |> Enum.join(";")

    case :os.find_executable(to_charlist(name), to_charlist(path)) do
      false ->
        {:error, name, "Couldn't find an #{name} executable"}

      elixir ->
        env =
          System.get_env()
          |> Enum.reject(fn {key, _} -> key == "ERLEXEC_DIR" end)
          |> Enum.map(fn
            {key, _path} when key in ["PATH", "Path"] -> {key, path}
            other -> other
          end)

        {:ok, elixir, env}
    end
  end

  defp find_project_executable_unix(%Project{} = project, name) do
    root_path = Project.root_path(project)

    # Filter out Expert's release paths from current PATH
    current_path = System.get_env("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    release_root = System.get_env("RELEASE_ROOT")

    path =
      if release_root do
        current_path
        |> String.split(":")
        |> Enum.reject(fn entry -> String.starts_with?(entry, release_root) end)
        |> Enum.join(":")
      else
        current_path
      end

    case :os.find_executable(to_charlist(name), to_charlist(path)) do
      false ->
        {:error, name, "Couldn't find an #{name} executable for project at #{root_path}"}

      elixir ->
        env =
          Enum.map(System.get_env(), fn
            {"PATH", _path} -> {"PATH", path}
            other -> other
          end)

        {:ok, elixir, env}
    end
  end

  defp fallback_executable(name) do
    case System.find_executable(name) do
      nil ->
        {:error, name, "Couldn't find any #{name} executable"}

      elixir ->
        {:ok, to_charlist(elixir), []}
    end
  end

  defp open_executable(executable, opts) do
    {os_type, _} = Forge.OS.type()

    opts =
      if Keyword.has_key?(opts, :env) do
        Keyword.update!(opts, :env, &ensure_charlists/1)
      else
        opts
      end

    open_port(os_type, executable, opts)
  end

  defp open_port(:win32, executable, opts) do
    executable_str = to_string(executable)

    {launcher, opts} =
      if String.ends_with?(executable_str, ".cmd") or String.ends_with?(executable_str, ".bat") do
        cmd_exe = "cmd" |> System.find_executable() |> to_charlist()

        opts =
          Keyword.update(opts, :args, ["/c", executable_str], fn args ->
            ["/c", executable_str | args]
          end)

        {cmd_exe, [:hide | opts]}
      else
        {executable, opts}
      end

    Port.open({:spawn_executable, launcher}, [:binary, :stderr_to_stdout, :exit_status | opts])
  end

  defp open_port(:unix, executable, opts) do
    launcher = port_wrapper_path()

    opts =
      Keyword.update(opts, :args, [executable], fn old_args ->
        [executable | Enum.map(old_args, &to_string/1)]
      end)

    Port.open({:spawn_executable, launcher}, [:binary, :stderr_to_stdout, :exit_status | opts])
  end

  defp port_wrapper_path do
    with :non_existing <- :code.where_is_file(~c"port_wrapper.sh") do
      :expert
      |> :code.priv_dir()
      |> Path.join("port_wrapper.sh")
      |> Path.expand()
    end
    |> to_string()
  end

  defp ensure_charlists(environment_variables) do
    Enum.map(environment_variables, fn {key, value} ->
      # using to_string ensures nil values won't blow things up
      erl_key = key |> to_string() |> String.to_charlist()
      erl_value = value |> to_string() |> String.to_charlist()
      {erl_key, erl_value}
    end)
  end
end
