defmodule Expert.Port do
  @moduledoc """
  Utilities for launching ports in the context of a project
  """

  alias Forge.Project

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
  @spec open_elixir(Project.t(), open_opts()) :: port()
  def open_elixir(%Project{} = project, opts) do
    {:ok, elixir_executable, environment_variables} = elixir_executable(project)

    opts =
      opts
      |> Keyword.put_new_lazy(:cd, fn -> Project.root_path(project) end)
      |> Keyword.put_new(:env, environment_variables)

    open(project, elixir_executable, opts)
  end

  def elixir_executable(%Project{} = project) do
    root_path = Project.root_path(project)

    {path_result, env} =
      with nil <- version_manager_path_and_env("asdf", root_path),
           nil <- version_manager_path_and_env("mise", root_path),
           nil <- version_manager_path_and_env("rtx", root_path) do
        {File.cd!(root_path, fn -> System.find_executable("elixir") end), System.get_env()}
      end

    case path_result do
      nil ->
        {:error, :no_elixir}

      executable when is_binary(executable) ->
        {:ok, executable, env}
    end
  end

  defp version_manager_path_and_env(manager, root_path) do
    with true <- is_binary(System.find_executable(manager)),
         env = reset_env(manager, root_path),
         {path, 0} <- System.cmd(manager, ~w(which elixir), cd: root_path, env: env) do
      {String.trim(path), env}
    else
      _ ->
        nil
    end
  end

  # We launch expert by asking the version managers to provide an environment,
  # which contains path munging. This initial environment is present in the running
  # VM, and needs to be undone so we can find the correct elixir executable in the project.
  defp reset_env("asdf", _root_path) do
    orig_path = System.get_env("PATH_SAVE", System.get_env("PATH"))

    Enum.map(System.get_env(), fn
      {"ASDF_ELIXIR_VERSION", _} -> {"ASDF_ELIXIR_VERSION", nil}
      {"ASDF_ERLANG_VERSION", _} -> {"ASDF_ERLANG_VERSION", nil}
      {"PATH", _} -> {"PATH", orig_path}
      other -> other
    end)
  end

  defp reset_env("rtx", root_path) do
    {env, _} = System.cmd("rtx", ~w(env -s bash), cd: root_path)

    env
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(fn
      "export " <> key_and_value ->
        [key, value] =
          key_and_value
          |> String.split("=", parts: 2)
          |> Enum.map(&String.trim/1)

        {key, value}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp reset_env("mise", root_path) do
    {env, _} = System.cmd("mise", ~w(env -s bash), cd: root_path)

    env
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(fn
      "export " <> key_and_value ->
        [key, value] =
          key_and_value
          |> String.split("=", parts: 2)
          |> Enum.map(&String.trim/1)

        {key, value}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
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

    Port.open({:spawn_executable, launcher}, opts)
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

  defp ensure_charlists(environment_variables) do
    Enum.map(environment_variables, fn {key, value} ->
      # using to_string ensures nil values won't blow things up
      erl_key = key |> to_string() |> String.to_charlist()
      erl_value = value |> to_string() |> String.to_charlist()
      {erl_key, erl_value}
    end)
  end
end
