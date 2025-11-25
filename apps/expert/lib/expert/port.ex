defmodule Expert.Port do
  @moduledoc """
  Utilities for launching ports in the context of a project
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
        |> Keyword.put_new(:env, environment_variables)

      open(project, elixir_executable, opts)
    end
  end

  def elixir_executable(%Project{} = project) do
    root_path = Project.root_path(project)

    shell = System.get_env("SHELL")
    path = path_env_at_directory(root_path, shell)

    case :os.find_executable(~c"elixir", to_charlist(path)) do
      false ->
        {:error, :no_elixir,
         "Couldn't find an elixir executable for project at #{root_path}. Using shell at #{shell} with PATH=#{path}"}

      elixir ->
        env =
          Enum.map(System.get_env(), fn
            {"PATH", _path} -> {"PATH", path}
            other -> other
          end)

        {:ok, elixir, env}
    end
  end

  defp path_env_at_directory(directory, shell) do
    # We run a shell in interactive mode to populate the PATH with the right value
    # at the project root. Otherwise, we either can't find an elixir executable,
    # we use the wrong version if the user uses a version manager like asdf/mise,
    # or we get an incomplete PATH not including erl or any other version manager
    # managed programs.

    env = [{"SHELL_SESSIONS_DISABLE", "1"}]

    path =
      case Path.basename(shell) do
        # Ideally, it should contain the path to shell (e.g. `/usr/bin/fish`),
        # but it might contain only the name of the shell (e.g. `fish`).
        "fish" ->
          # Fish uses space-separated PATH, so we use the built-in `string join` command
          # to join the entries with colons and have a standard colon-separated PATH output
          # as in bash, which is expected by `:os.find_executable/2`.
          {path, 0} =
            System.cmd(shell, ["-l", "-c", "cd #{directory} && string join ':' $PATH"], env: env)

          path

        _ ->
          {path, 0} =
            System.cmd(shell, ["-i", "-l", "-c", "cd #{directory} && echo $PATH"], env: env)

          path
      end

    path
    |> String.trim()
    |> String.split("\n")
    |> List.last()
  end

  @doc """
  Launches an executable in the project context via a port.
  """
  def open(%Project{} = project, executable, opts) do
    {launcher, opts} = Keyword.pop_lazy(opts, :path, &path/0)

    opts =
      opts
      |> Keyword.put_new_lazy(:cd, fn -> Project.root_path(project) end)
      |> Keyword.update(:args, [executable], fn old_args ->
        [executable | Enum.map(old_args, &to_string/1)]
      end)

    opts =
      if Keyword.has_key?(opts, :env) do
        Keyword.update!(opts, :env, &ensure_charlists/1)
      else
        opts
      end

    Port.open({:spawn_executable, launcher}, [:stderr_to_stdout | opts])
  end

  @doc """
  Provides the path of an executable to launch another erlang node via ports.
  """
  def path do
    path(:os.type())
  end

  def path({:unix, _}) do
    with :non_existing <- :code.where_is_file(~c"port_wrapper.sh") do
      :expert
      |> :code.priv_dir()
      |> Path.join("port_wrapper.sh")
      |> Path.expand()
    end
    |> to_string()
  end

  def path(os_tuple) do
    raise ArgumentError, "Operating system #{inspect(os_tuple)} is not currently supported"
  end

  def ensure_charlists(environment_variables) do
    Enum.map(environment_variables, fn {key, value} ->
      # using to_string ensures nil values won't blow things up
      erl_key = key |> to_string() |> String.to_charlist()
      erl_value = value |> to_string() |> String.to_charlist()
      {erl_key, erl_value}
    end)
  end
end
