defmodule Expert.EngineNode.Builder do
  @moduledoc """
  Builds the engine node for a project.
  """
  alias Forge.Project
  require Logger

  use GenServer

  defmodule State do
    defstruct [:project, :last_line, :from, :port, :mix_home, :buffer, attempts: 0]
  end

  @max_attempts 1

  def build_engine(project) do
    with {:ok, pid} <- start_link(project) do
      GenServer.call(pid, :build, :infinity)
    end
  end

  def start_link(project) do
    GenServer.start_link(__MODULE__, project)
  end

  @impl GenServer
  def init(project) do
    {:ok, %State{project: project, last_line: "", buffer: ""}}
  end

  @impl GenServer
  def handle_call(:build, from, state) do
    state =
      case start_build(state.project, from) do
        {:ok, port} ->
          %State{state | port: port}

        _ ->
          state
      end

    {:noreply, %State{state | from: from}}
  end

  @impl GenServer
  def handle_info({_port, {:data, {:noeol, line}}}, state) do
    {:noreply, %State{state | buffer: state.buffer <> line}}
  end

  def handle_info({_port, {:data, {:eol, line}}}, state) do
    chunk = state.buffer <> line
    line = String.trim(chunk)
    state = %State{state | buffer: ""}

    state =
      if line == "" do
        state
      else
        %State{state | last_line: line}
      end

    case parse_engine_meta(line) do
      {:ok, mix_home, engine_path} ->
        Logger.info("Engine available at: #{engine_path}", project: state.project)

        Logger.info("ebin paths:\n#{inspect(ebin_paths(engine_path), pretty: true)}",
          project: state.project
        )

        GenServer.reply(state.from, {:ok, {ebin_paths(engine_path), mix_home}})
        {:stop, :normal, state}

      :error ->
        if detect_deps_error(line) do
          handle_deps_error(line, state)
        else
          Logger.debug("Engine build output: #{line}", project: state.project)
          {:noreply, state}
        end
    end
  end

  def handle_info({_port, {:exit_status, 0}}, state) do
    {:noreply, state}
  end

  def handle_info({_port, {:exit_status, status}}, state) do
    Logger.error("Engine build script exited with status: #{status}", project: state.project)

    GenServer.reply(
      state.from,
      {:error, "Build script exited with status: #{status}", state.last_line}
    )

    {:stop, :normal, state}
  end

  def handle_info({:EXIT, port, reason}, %State{port: port} = state) when reason != :normal do
    Logger.error("Engine build script exited with reason: #{inspect(reason)}",
      project: state.project
    )

    GenServer.reply(state.from, {:error, reason, state.last_line})
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _port, _reason}, state) do
    {:noreply, state}
  end

  if Mix.env() == :test do
    # In test environment, Expert depends on the Engine app, so we look for it
    # in the expert build path.
    @excluded_apps [:patch, :nimble_parsec]
    @allowed_apps [:engine | Mix.Project.deps_apps()] -- @excluded_apps

    def start_build(_, from, _ \\ []) do
      entries =
        [Mix.Project.build_path(), "**/ebin"]
        |> Forge.Path.glob()
        |> Enum.filter(fn entry ->
          Enum.any?(@allowed_apps, &String.contains?(entry, to_string(&1)))
        end)

      GenServer.reply(from, {:ok, {entries, nil}})
      {:ok, :fake_port}
    end

    def close_port(_port), do: :ok
  else
    # In dev and prod environments, the engine source code is included in the
    # Expert release, and we build it on the fly for the project elixir+opt
    # versions if it was not built yet.
    defp start_build(%Project{} = project, from, opts \\ []) do
      with {:ok, elixir, env} <- Expert.Port.project_executable(project, "elixir"),
           {:ok, erl, _env} <- Expert.Port.project_executable(project, "erl") do
        Logger.info("Using path: #{System.get_env("PATH")}", project: project)
        Logger.info("Found elixir executable at #{elixir}", project: project)
        Logger.info("Found erl executable at #{erl}", project: project)

        port = launch_engine_builder(project, elixir, env, opts)
        {:ok, port}
      else
        {:error, name, message} = error ->
          Logger.error(message, project: project)
          GenServer.reply(from, {:error, message})
          Expert.terminate("Failed to find an #{name} executable, shutting down", 1)
          error
      end
    end

    defp close_port(port), do: Port.close(port)
  end

  def launch_engine_builder(project, elixir, env, opts \\ []) do
    expert_priv = :code.priv_dir(:expert)
    packaged_engine_source = Path.join([expert_priv, "engine_source", "apps", "engine"])

    engine_source =
      "EXPERT_ENGINE_PATH"
      |> System.get_env(packaged_engine_source)
      |> Path.expand()

    build_engine_script = Path.join(expert_priv, "build_engine.exs")
    cache_dir = Forge.Path.expert_cache_dir()

    args = [
      build_engine_script,
      "--source-path",
      engine_source,
      "--vsn",
      Expert.vsn(),
      "--cache-dir",
      cache_dir
    ]

    args =
      if opts[:force] do
        args ++ ["--force"]
      else
        args
      end

    Logger.info("Preparing engine", project: project)

    Process.flag(:trap_exit, true)

    env = [{"MIX_ENV", "dev"} | env]

    Expert.Port.open_elixir_with_env(elixir, env,
      args: args,
      cd: Project.root_path(project),
      line: 4096
    )
  end

  defp ebin_paths(base_path) do
    Forge.Path.glob([base_path, "lib/**/ebin"])
  end

  defp handle_deps_error(line, state) do
    if state.attempts < @max_attempts do
      Logger.warning(
        "Detected dependency errors during engine build, retrying... (attempt #{state.attempts + 1}/#{@max_attempts})",
        project: state.project
      )

      close_port(state.port)

      state =
        case start_build(state.project, state.from, force: true) do
          {:ok, port} ->
            %State{state | port: port}

          _ ->
            state
        end

      {:noreply, %State{state | attempts: state.attempts + 1}}
    else
      Logger.error("Maximum build attempts reached. Failing the build.", project: state.project)

      GenServer.reply(
        state.from,
        {:error, "Build failed due to dependency errors after #{@max_attempts} attempts", line}
      )

      {:stop, :normal, state}
    end
  end

  defp parse_engine_meta("engine_meta:" <> meta) do
    meta = String.trim(meta)

    with {:ok, binary} <- Base.decode64(meta),
         %{mix_home: mix_home, engine_path: engine_path} <- :erlang.binary_to_term(binary) do
      {:ok, mix_home, engine_path}
    else
      _ -> :error
    end
  end

  defp parse_engine_meta(_), do: :error

  @deps_error_patterns [
    "Can't continue due to errors on dependencies",
    "Unchecked dependencies"
  ]
  defp detect_deps_error(message) when is_binary(message) do
    Enum.any?(@deps_error_patterns, &String.contains?(message, &1))
  end
end
