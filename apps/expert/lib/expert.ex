defmodule Expert do
  alias Expert.Provider.Handlers
  alias Expert.State
  alias Forge.Protocol.Convert
  alias Forge.Protocol.Id
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
    GenLSP.Notifications.Initialized,
    GenLSP.Requests.Shutdown
  ]

  @dialyzer {:nowarn_function, apply_to_state: 2}

  def get_lsp, do: :persistent_term.get(:expert_lsp, nil)

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
    Process.send_after(self(), :default_config, :timer.seconds(5))

    case State.initialize(state, request) do
      {:ok, response, state} ->
        # TODO: this should be gated behind the dynamic registration in the initialization params
        registrations = registrations()

        if nil != GenLSP.request(lsp, registrations) do
          Logger.error("Failed to register capability")
        end

        lsp = assign(lsp, state: state)
        {:ok, response} = Forge.Protocol.Convert.to_lsp(response)

        {:reply, response, lsp}

      {:error, error} ->
        response = %GenLSP.ErrorResponse{
          code: GenLSP.Enumerations.ErrorCodes.invalid_request(),
          message: to_string(error)
        }

        {:reply, response, lsp}
    end
  end

  def handle_request(%mod{} = request, lsp) when mod in @server_specific_messages do
    GenLSP.error(lsp, "handling server specific request #{Macro.to_string(mod)}")

    with {:ok, request} <- Forge.Protocol.Convert.to_native(request),
         {:ok, response, state} <- apply_to_state(assigns(lsp).state, request),
         {:ok, response} <- Forge.Protocol.Convert.to_lsp(response) do
      {:reply, Forge.Protocol.Convert.to_lsp(response), assign(lsp, state: state)}
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

    with {:ok, handler} <- fetch_handler(request),
         {:ok, request} <- Convert.to_native(request),
         {:ok, response} <- handler.handle(request, state.configuration),
         {:ok, response} <- Forge.Protocol.Convert.to_lsp(response) do
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

  def handle_info(:default_config, lsp) do
    state = assigns(lsp).state

    if state.configuration == nil do
      Logger.warning(
        "Did not receive workspace/didChangeConfiguration notification after 5 seconds. " <>
          "Using default settings."
      )

      {:ok, config} = State.default_configuration(state)
      {:noreply, assign(lsp, state: %State{state | configuration: config})}
    else
      {:noreply, lsp}
    end
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
end
