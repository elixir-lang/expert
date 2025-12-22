defmodule Expert do
  alias Expert.Project
  alias Expert.Protocol.Convert
  alias Expert.Protocol.Id
  alias Expert.Provider.Handlers
  alias Expert.State
  alias GenLSP.Enumerations
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  use GenLSP

  @server_specific_messages [
    GenLSP.Notifications.TextDocumentDidChange,
    GenLSP.Notifications.WorkspaceDidChangeConfiguration,
    GenLSP.Notifications.WorkspaceDidChangeWatchedFiles,
    GenLSP.Notifications.TextDocumentDidClose,
    GenLSP.Notifications.TextDocumentDidOpen,
    GenLSP.Notifications.TextDocumentDidSave,
    GenLSP.Notifications.Exit,
    GenLSP.Requests.Shutdown
  ]

  @dialyzer {:nowarn_function, apply_to_state: 2}

  @version Mix.Project.config()[:version]

  def vsn, do: @version

  def get_lsp, do: :persistent_term.get(:expert_lsp, nil)

  def terminate(message, status \\ 0) do
    Logger.error(message)
    System.stop(status)
  end

  def start_link(args) do
    Logger.debug(inspect(args))

    GenLSP.start_link(
      __MODULE__,
      [],
      Keyword.take(args, [:buffer, :assigns, :task_supervisor, :name])
    )
  end

  def init(lsp, _args) do
    :persistent_term.put(:expert_lsp, lsp)
    {:ok, assign(lsp, state: State.new())}
  end

  def handle_request(%GenLSP.Requests.Initialize{} = request, lsp) do
    state = assigns(lsp).state

    with {:ok, response, state} <- State.initialize(state, request),
         {:ok, response} <- Expert.Protocol.Convert.to_lsp(response) do
      Task.Supervisor.start_child(:expert_task_queue, fn ->
        config = state.configuration

        log_info(lsp, "Starting project")

        start_result = Project.Supervisor.start(config.project)

        send(Expert, {:engine_initialized, start_result})
      end)

      {:reply, response, assign(lsp, state: state)}
    else
      {:error, :already_initialized} ->
        response = %GenLSP.ErrorResponse{
          code: GenLSP.Enumerations.ErrorCodes.invalid_request(),
          message: "Already initialized"
        }

        {:reply, response, lsp}

      {:error, reason} ->
        response = %GenLSP.ErrorResponse{
          code: GenLSP.Enumerations.ErrorCodes.server_not_initialized(),
          message: "Failed to initialize: #{inspect(reason)}"
        }

        {:reply, response, lsp}
    end
  end

  def handle_request(%mod{} = request, lsp) when mod in @server_specific_messages do
    GenLSP.error(lsp, "handling server specific request #{Macro.to_string(mod)}")

    with {:ok, request} <- Expert.Protocol.Convert.to_native(request),
         {:ok, response, state} <- apply_to_state(assigns(lsp).state, request),
         {:ok, response} <- Expert.Protocol.Convert.to_lsp(response) do
      {:reply, response, assign(lsp, state: state)}
    else
      error ->
        message = "Failed to handle #{mod}, #{inspect(error)}"
        Logger.error(message)

        {:reply,
         %GenLSP.ErrorResponse{
           code: GenLSP.Enumerations.ErrorCodes.internal_error(),
           message: message
         }, lsp}
    end
  end

  def handle_request(request, lsp) do
    state = assigns(lsp).state

    if state.engine_initialized? do
      with {:ok, handler} <- fetch_handler(request),
           {:ok, request} <- Convert.to_native(request),
           {:ok, response} <- handler.handle(request, state.configuration),
           {:ok, response} <- Expert.Protocol.Convert.to_lsp(response) do
        {:reply, response, lsp}
      else
        {:error, {:unhandled, _}} ->
          Logger.info("Unhandled request: #{request.method}")

          {:reply,
           %GenLSP.ErrorResponse{
             code: GenLSP.Enumerations.ErrorCodes.method_not_found(),
             message: "Method not found"
           }, lsp}

        error ->
          message = "Failed to handle #{request.method}, #{inspect(error)}"
          Logger.error(message)

          {:reply,
           %GenLSP.ErrorResponse{
             code: GenLSP.Enumerations.ErrorCodes.internal_error(),
             message: message
           }, lsp}
      end
    else
      GenLSP.warning(
        lsp,
        "Received request #{request.method} before engine was initialized. Ignoring."
      )

      {:noreply, lsp}
    end
  end

  def handle_notification(%GenLSP.Notifications.Initialized{}, lsp) do
    registrations = registrations()

    if nil != GenLSP.request(lsp, registrations) do
      Logger.error("Failed to register capability")
    end

    {:noreply, lsp}
  end

  def handle_notification(%mod{} = notification, lsp) when mod in @server_specific_messages do
    with {:ok, notification} <- Convert.to_native(notification),
         {:ok, state} <- apply_to_state(assigns(lsp).state, notification) do
      {:noreply, assign(lsp, state: state)}
    else
      error ->
        message = "Failed to handle #{notification.method}, #{inspect(error)}"
        Logger.error(message)

        {:noreply, lsp}
    end
  end

  def handle_notification(notification, lsp) do
    state = assigns(lsp).state

    with {:ok, handler} <- fetch_handler(notification),
         {:ok, notification} <- Convert.to_native(notification),
         {:ok, _response} <- handler.handle(notification, state.configuration) do
      {:noreply, lsp}
    else
      {:error, {:unhandled, _}} ->
        Logger.info("Unhandled notification: #{notification.method}")

        {:noreply, lsp}

      error ->
        message = "Failed to handle #{notification.method}, #{inspect(error)}"
        Logger.error(message)

        {:noreply, lsp}
    end
  end

  def handle_info({:engine_initialized, {:ok, _pid}}, lsp) do
    state = assigns(lsp).state

    new_state = %{state | engine_initialized?: true}

    lsp = assign(lsp, state: new_state)

    Logger.info("Engine initialized")

    {:noreply, lsp}
  end

  def handle_info({:engine_initialized, {:error, reason}}, lsp) do
    error_message = initialization_error_message(reason)
    log_error(lsp, error_message)

    {:noreply, lsp}
  end

  def log_info(lsp \\ get_lsp(), message) do
    message = log_prepend_project_root(message, assigns(lsp).state)

    Logger.info(message)
    GenLSP.info(lsp, message)
  end

  # When logging errors we also notify the client to display the message
  def log_error(lsp \\ get_lsp(), message) do
    message = log_prepend_project_root(message, assigns(lsp).state)

    Logger.error(message)
    GenLSP.error(lsp, message)

    GenLSP.notify(lsp, %GenLSP.Notifications.WindowShowMessage{
      params: %GenLSP.Structures.ShowMessageParams{
        type: Enumerations.MessageType.error(),
        message: message
      }
    })
  end

  defp apply_to_state(%State{} = state, %{} = request_or_notification) do
    case State.apply(state, request_or_notification) do
      {:ok, response, new_state} -> {:ok, response, new_state}
      {:ok, state} -> {:ok, state}
      :ok -> {:ok, state}
      error -> {error, state}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp fetch_handler(%_{} = request) do
    case request do
      %Requests.TextDocumentReferences{} ->
        {:ok, Handlers.FindReferences}

      %Requests.TextDocumentFormatting{} ->
        {:ok, Handlers.Formatting}

      %Requests.TextDocumentCodeAction{} ->
        {:ok, Handlers.CodeAction}

      %Requests.TextDocumentCodeLens{} ->
        {:ok, Handlers.CodeLens}

      %Requests.TextDocumentCompletion{} ->
        {:ok, Handlers.Completion}

      %Requests.TextDocumentDefinition{} ->
        {:ok, Handlers.GoToDefinition}

      %Requests.TextDocumentHover{} ->
        {:ok, Handlers.Hover}

      %Requests.WorkspaceExecuteCommand{} ->
        {:ok, Handlers.Commands}

      %Requests.TextDocumentDocumentSymbol{} ->
        {:ok, Handlers.DocumentSymbols}

      %GenLSP.Requests.WorkspaceSymbol{} ->
        {:ok, Handlers.WorkspaceSymbol}

      %request_module{} ->
        {:error, {:unhandled, request_module}}
    end
  end

  defp registrations do
    %Requests.ClientRegisterCapability{
      id: Id.next(),
      params: %GenLSP.Structures.RegistrationParams{
        registrations: [file_watcher_registration()]
      }
    }
  end

  @did_changed_watched_files_id "-42"
  @watched_extensions ~w(ex exs)
  defp file_watcher_registration do
    extension_glob = "{" <> Enum.join(@watched_extensions, ",") <> "}"

    watchers = [
      %Structures.FileSystemWatcher{glob_pattern: "**/mix.lock"},
      %Structures.FileSystemWatcher{glob_pattern: "**/*.#{extension_glob}"}
    ]

    %Structures.Registration{
      id: @did_changed_watched_files_id,
      method: "workspace/didChangeWatchedFiles",
      register_options: %Structures.DidChangeWatchedFilesRegistrationOptions{watchers: watchers}
    }
  end

  defp initialization_error_message({:shutdown, {:failed_to_start_child, child, reason}}) do
    case child do
      {Project.Node, node_name} ->
        node_initialization_message(node_name, reason)

      child ->
        "Failed to start child #{inspect(child)}: #{inspect(reason)}"
    end
  end

  defp initialization_error_message(reason) do
    "Failed to initialize: #{inspect(reason)}"
  end

  defp node_initialization_message(name, reason) do
    case reason do
      # NOTE: {:error, :normal, ~c"could not compile dependency :elixir_sense..."}
      {:error, :normal, message} ->
        "Engine #{name} initialization failed with error:\n\n#{message}"

      # NOTE:
      # ** (Mix.Error) httpc request failed with: ... Could not install Hex because Mix could not download metadata ...
      {{:shutdown, {:error, :normal, message}}, _} ->
        "Engine #{name} shut down with error:\n\n#{message}"

      {{:shutdown, {:node_exit, node_exit}}, _} ->
        "Engine #{name} exit with status #{node_exit.status}, last message:\n\n#{node_exit.last_message}"

      reason ->
        "Failed to start engine #{name}: #{inspect(reason)}"
    end
  end

  defp log_prepend_project_root(message, %State{
         configuration: %Expert.Configuration{project: %Forge.Project{} = project}
       }) do
    "[Project #{project.root_uri}] #{message}"
  end

  defp log_prepend_project_root(message, _state), do: message
end
