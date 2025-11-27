defmodule Expert.EngineNode do
  alias Forge.Project
  require Logger

  use Expert.Project.Progress.Support

  defmodule State do
    require Logger

    defstruct [
      :project,
      :port,
      :cookie,
      :stopped_by,
      :stop_timeout,
      :started_by,
      :last_message,
      :status
    ]

    def new(%Project{} = project) do
      cookie = Node.get_cookie()

      %__MODULE__{
        project: project,
        cookie: cookie,
        status: :initializing
      }
    end

    @dialyzer {:nowarn_function, start: 3}

    def start(%__MODULE__{} = state, paths, from) do
      this_node = to_string(Node.self())
      dist_port = Forge.EPMD.dist_port()

      args =
        [
          "--erl",
          "-start_epmd false -epmd_module #{Forge.EPMD}",
          "--cookie",
          state.cookie,
          "--no-halt",
          "-e",
          "System.argv() |> hd() |> Base.decode64!() |> Code.eval_string()",
          project_node_eval_string(state.project)
          | path_append_arguments(paths)
        ]

      env =
        [
          {"EXPERT_PARENT_NODE", this_node},
          {"EXPERT_PARENT_PORT", to_string(dist_port)}
        ]

      case Expert.Port.open_elixir(state.project, args: args, env: env) do
        {:error, :no_elixir, message} ->
          GenLSP.error(Expert.get_lsp(), message)
          Expert.terminate("Failed to find an elixir executable, shutting down", 1)
          {:error, :no_elixir}

        port ->
          state = %{state | port: port, started_by: from}
          {:ok, state}
      end
    end

    defp project_node_eval_string(project) do
      # We pass the child node code as --eval argument. Windows handles
      # escaped quotes and newlines differently from Unix, so to avoid
      # those kind of issues, we encode the string in base 64 and pass
      # as positional argument. Then, we use a simple --eval that decodes
      # and evaluates the string.
      project_node = Project.node_name(project)
      port_mapper = Forge.NodePortMapper

      code =
        quote do
          node = unquote(project_node)

          # We start distribution here, rather than on node boot, so that
          # -pa takes effect and Forge.EPMD is available
          node_start = Node.start(node, :longnames)

          case node_start do
            {:ok, _} ->
              unquote(port_mapper).register()
              IO.puts("ok")
            {:error, reason} ->
              IO.puts("error starting node:\n \#{inspect(reason)}")
          end
        end

      code
      |> Macro.to_string()
      |> Base.encode64()
    end

    def stop(%__MODULE__{} = state, from, stop_timeout) do
      project_rpc(state, System, :stop)
      %{state | stopped_by: from, stop_timeout: stop_timeout, status: :stopping}
    end

    def halt(%__MODULE__{} = state) do
      project_rpc(state, System, :halt)
      %{state | status: :stopped}
    end

    def on_nodeup(%__MODULE__{} = state, node_name) do
      if String.starts_with?(to_string(node_name), to_string(Project.node_name(state.project))) do
        {pid, _ref} = state.started_by
        Process.monitor(pid)
        GenServer.reply(state.started_by, :ok)

        %{state | status: :started}
      else
        state
      end
    end

    def on_nodedown(%__MODULE__{} = state, node_name) do
      if node_name == Project.node_name(state.project) do
        maybe_reply_to_stopper(state)
        {:shutdown, %{state | status: :stopped}}
      else
        :continue
      end
    end

    def on_exit_status(%__MODULE__{} = state, exit_status) do
      stop_reason =
        case exit_status do
          0 ->
            project = state.project
            Logger.info("Engine for #{project.root_uri} shut down")

            :shutdown

          _error_status ->
            Logger.error(
              "Engine shut down unexpectedly, node exited with status #{exit_status}). Last message: #{state.last_message}"
            )

            {:shutdown, {:node_exit, %{status: exit_status, last_message: state.last_message}}}
        end

      new_state = %{state | status: :stopped}

      {stop_reason, new_state}
    end

    def maybe_reply_to_stopper(%State{stopped_by: stopped_by} = state)
        when is_tuple(stopped_by) do
      GenServer.reply(state.stopped_by, :ok)
    end

    def maybe_reply_to_stopper(%State{}), do: :ok

    def on_monitored_dead(%__MODULE__{} = state) do
      if project_rpc(state, Node, :alive?) do
        halt(state)
      else
        %{state | status: :stopped}
      end
    end

    defp path_append_arguments(paths) do
      Enum.flat_map(paths, fn path ->
        ["-pa", Path.expand(path)]
      end)
    end

    defp project_rpc(%__MODULE__{} = state, module, function, args \\ []) do
      state.project
      |> Project.node_name()
      |> :rpc.call(module, function, args)
    end
  end

  alias Expert.EngineSupervisor
  alias Forge.Document
  use GenServer

  def start(project) do
    start_net_kernel(project)

    node_name = Project.node_name(project)
    bootstrap_args = [project, Document.Store.entropy(), all_app_configs()]

    with {:ok, node_pid} <- EngineSupervisor.start_project_node(project),
         {:ok, glob_paths} <- glob_paths(project),
         :ok <- start_node(project, glob_paths),
         :ok <- :rpc.call(node_name, Engine.Bootstrap, :init, bootstrap_args),
         :ok <- ensure_apps_started(node_name) do
      {:ok, node_name, node_pid}
    end
  end

  defp start_net_kernel(%Project{} = project) do
    manager = Project.manager_node_name(project)
    Node.start(manager, :longnames)
  end

  defp ensure_apps_started(node) do
    :rpc.call(node, Engine, :ensure_apps_started, [])
  end

  if Mix.env() == :test do
    # In test environment, Expert depends on the Engine app, so we look for it
    # in the expert build path.
    @excluded_apps [:patch, :nimble_parsec]
    @allowed_apps [:engine | Mix.Project.deps_apps()] -- @excluded_apps

    def glob_paths(_) do
      entries =
        [Mix.Project.build_path(), "**/ebin"]
        |> Forge.Path.glob()
        |> Enum.filter(fn entry ->
          Enum.any?(@allowed_apps, &String.contains?(entry, to_string(&1)))
        end)

      {:ok, entries}
    end
  else
    # In dev and prod environments, the engine source code is included in the
    # Expert release, and we build it on the fly for the project elixir+opt
    # versions if it was not built yet.
    defp glob_paths(%Project{} = project) do
      case Expert.Port.elixir_executable(project) do
        {:ok, elixir, env} ->
          launch_engine_builder(project, elixir, env)

        {:error, :no_elixir, message} ->
          GenLSP.error(Expert.get_lsp(), message)
          Expert.terminate("Failed to find an elixir executable, shutting down", 1)
      end
    end

    defp launch_engine_builder(project, elixir, env) do
      lsp = Expert.get_lsp()

      project_name = Project.name(project)
      Logger.info("Found elixir for #{project_name} at #{elixir}")
      GenLSP.info(lsp, "Found elixir for #{project_name} at #{elixir}")

      expert_priv = :code.priv_dir(:expert)
      packaged_engine_source = Path.join([expert_priv, "engine_source", "apps", "engine"])

      engine_source =
        "EXPERT_ENGINE_PATH"
        |> System.get_env(packaged_engine_source)
        |> Path.expand()

      build_engine_script = Path.join(expert_priv, "build_engine.exs")

      opts =
        [
          args: [
            build_engine_script,
            "--source-path",
            engine_source,
            "--vsn",
            Expert.vsn()
          ],
          env: Expert.Port.ensure_charlists(env),
          cd: Project.root_path(project)
        ]

      {launcher, opts} =
        if Forge.OS.windows?() do
          {elixir, opts}
        else
          launcher = Expert.Port.path()

          opts =
            Keyword.update(opts, :args, [elixir], fn old_args ->
              [elixir | Enum.map(old_args, &to_string/1)]
            end)

          {launcher, opts}
        end

      GenLSP.info(lsp, "Finding or building engine for project #{project_name}")

      with_progress(project, "Building engine for #{project_name}", fn ->
        fn ->
          Process.flag(:trap_exit, true)

          {:spawn_executable, launcher}
          |> Port.open([:stderr_to_stdout | opts])
          |> wait_for_engine()
        end
        |> Task.async()
        |> Task.await(:infinity)
      end)
    end

    defp wait_for_engine(port, last_line \\ "") do
      receive do
        {^port, {:data, ~c"engine_path:" ++ engine_path}} ->
          engine_path = engine_path |> to_string() |> String.trim()
          Logger.info("Engine build available at: #{engine_path}")

          Logger.info("ebin paths:\n#{inspect(ebin_paths(engine_path), pretty: true)}")

          {:ok, ebin_paths(engine_path)}

        {^port, {:data, data}} ->
          Logger.debug("Building engine: #{to_string(data)}")
          wait_for_engine(port, data)

        {:EXIT, ^port, reason} ->
          Logger.error("Engine build script exited with reason: #{inspect(reason)} #{last_line}")
          {:error, reason, last_line}
      end
    end

    defp ebin_paths(base_path) do
      Forge.Path.glob([base_path, "lib/**/ebin"])
    end
  end

  @stop_timeout 1_000

  def stop(%Project{} = project, stop_timeout \\ @stop_timeout) do
    project
    |> name()
    |> GenServer.call({:stop, stop_timeout}, stop_timeout + 100)
  end

  def child_spec(%Project{} = project) do
    %{
      id: name(project),
      start: {__MODULE__, :start_link, [project]},
      restart: :transient
    }
  end

  def start_link(%Project{} = project) do
    state = State.new(project)
    GenServer.start_link(__MODULE__, state, name: name(project))
  end

  @start_timeout 3_000

  defp start_node(project, paths) do
    project
    |> name()
    |> GenServer.call({:start, paths}, @start_timeout + 500)
  end

  @impl GenServer
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call({:start, paths}, from, %State{} = state) do
    :ok = :net_kernel.monitor_nodes(true, node_type: :all)
    Process.send_after(self(), :maybe_start_timeout, @start_timeout)

    case State.start(state, paths, from) do
      {:ok, state} ->
        {:noreply, state}

      {:error, :no_elixir} ->
        {:reply, {:error, :no_elixir}, state}
    end
  end

  @impl true
  def handle_call({:stop, stop_timeout}, from, %State{} = state) do
    state = State.stop(state, from, stop_timeout)
    {:noreply, state, stop_timeout}
  end

  @impl true
  def handle_info({:nodeup, node, _}, %State{} = state) do
    state = State.on_nodeup(state, node)
    {:noreply, state}
  end

  @impl true
  def handle_info(:maybe_start_timeout, %State{status: :started} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:maybe_start_timeout, %State{} = state) do
    GenServer.reply(state.started_by, {:error, :start_timeout})
    {:stop, :start_timeout, nil}
  end

  @impl true
  def handle_info({:nodedown, node_name, _}, %State{} = state) do
    case State.on_nodedown(state, node_name) do
      {:shutdown, new_state} ->
        {:stop, :shutdown, new_state}

      :continue ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _object, _reason}, %State{} = state) do
    state = State.on_monitored_dead(state)
    {:stop, :shutdown, state}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %State{port: port} = state) do
    Logger.info("Port #{inspect(port)} has exited due to: #{inspect(reason)}")
    {:noreply, %State{state | port: nil}}
  end

  @impl true
  def handle_info({:EXIT, port, _}, state) when is_port(port) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:timeout, %State{} = state) do
    state = State.halt(state)
    State.maybe_reply_to_stopper(state)
    {:stop, :shutdown, state}
  end

  @impl true
  def handle_info({_port, {:exit_status, exit_status}}, %State{} = state) do
    {stop_reason, state} = State.on_exit_status(state, exit_status)

    {:stop, stop_reason, state}
  end

  @impl true
  def handle_info({_port, {:data, data}}, %State{} = state) do
    message = to_string(data)
    Logger.debug("Node port message: #{message}")

    {:noreply, %{state | last_message: message}}
  end

  @impl true
  def handle_info(msg, %State{} = state) do
    Logger.warning("Received unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  def name(%Project{} = project) do
    :"#{Project.name(project)}::node_process"
  end

  @deps_apps Mix.Project.deps_apps()
  defp all_app_configs do
    Enum.map(@deps_apps, fn app_name ->
      {app_name, Application.get_all_env(app_name)}
    end)
  end
end
