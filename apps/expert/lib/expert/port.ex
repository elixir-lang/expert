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
  `Expert.EngineApi.elixir_executable(project)`. Environment variables are also retrieved with that call.
  """
  @spec open_elixir(Project.t(), open_opts()) :: port()
  def open_elixir(%Project{} = project, opts) do
    {:ok, elixir_executable, environment_variables} = Expert.EngineApi.elixir_executable(project)

    opts =
      opts
      |> Keyword.put_new_lazy(:cd, fn -> Project.root_path(project) end)
      |> Keyword.put_new(:env, environment_variables)

    open(project, elixir_executable, opts)
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
    require Logger

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
