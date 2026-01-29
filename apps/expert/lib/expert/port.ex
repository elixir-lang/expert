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
    with {:ok, elixir_executable, environment_variables} <- elixir_executable(project) do
      opts =
        opts
        |> Keyword.put_new_lazy(:cd, fn -> Project.root_path(project) end)
        |> Keyword.update(:env, environment_variables, fn env ->
          environment_variables ++ env
        end)

      open_executable(elixir_executable, opts)
    end
  end

  @doc """
  Returns the elixir executable path and environment for a project.

  Returns `{:ok, elixir_path, env}` where:
  - `elixir_path` is a charlist path to the elixir executable
  - `env` is a list of `{key, value}` tuples for the environment

  Returns `{:error, :no_elixir, reason}` if no elixir executable can be found.
  """
  @spec elixir_executable(Project.t()) ::
          {:ok, charlist(), list()} | {:error, :no_elixir, String.t()}
  def elixir_executable(%Project{} = project) do
    case find_project_elixir(project) do
      {:ok, _, _} = success ->
        success

      {:error, :no_elixir, reason} ->
        Logger.warning(
          "Failed to find elixir for project, falling back to packaged elixir: #{reason}"
        )

        fallback_elixir()
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

  # --- Private Functions ---

  defp find_project_elixir(%Project{} = project) do
    if Forge.OS.windows?() do
      find_project_elixir_windows()
    else
      find_project_elixir_unix(project)
    end
  end

  defp find_project_elixir_windows do
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

    case :os.find_executable(~c"elixir", to_charlist(path)) do
      false ->
        {:error, :no_elixir, "Couldn't find an elixir executable"}

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

  defp find_project_elixir_unix(%Project{} = project) do
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

    case :os.find_executable(~c"elixir", to_charlist(path)) do
      false ->
        {:error, :no_elixir,
         "Couldn't find an elixir executable for project at #{root_path}. Using PATH=#{path}"}

      elixir ->
        env =
          Enum.map(System.get_env(), fn
            {"PATH", _path} -> {"PATH", path}
            other -> other
          end)

        {:ok, elixir, env}
    end
  end

  defp fallback_elixir do
    case System.find_executable("elixir") do
      nil ->
        {:error, :no_elixir, "Couldn't find any elixir executable"}

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

    Port.open({:spawn_executable, launcher}, [:stderr_to_stdout, :exit_status | opts])
  end

  defp open_port(:unix, executable, opts) do
    launcher = port_wrapper_path()

    opts =
      Keyword.update(opts, :args, [executable], fn old_args ->
        [executable | Enum.map(old_args, &to_string/1)]
      end)

    Port.open({:spawn_executable, launcher}, [:stderr_to_stdout, :exit_status | opts])
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
