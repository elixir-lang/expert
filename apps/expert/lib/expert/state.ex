defmodule Expert.State do
  alias Expert.CodeIntelligence
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Expert.Project
  alias Expert.Provider.Handlers
  alias Forge.Document
  alias GenLSP.Enumerations
  alias GenLSP.Notifications
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  import Forge.EngineApi.Messages

  defstruct configuration: nil,
            initialized?: false,
            shutdown_received?: false,
            in_flight_requests: %{}

  @supported_code_actions [
    Enumerations.CodeActionKind.quick_fix(),
    Enumerations.CodeActionKind.refactor(),
    Enumerations.CodeActionKind.refactor_extract(),
    Enumerations.CodeActionKind.refactor_inline(),
    Enumerations.CodeActionKind.refactor_rewrite(),
    Enumerations.CodeActionKind.source(),
    Enumerations.CodeActionKind.source_fix_all(),
    Enumerations.CodeActionKind.source_organize_imports()
  ]

  def new do
    %__MODULE__{}
  end

  # TODO: this function has a side effect (starting the project supervisor)
  # that i think might be better off in the calling function
  def initialize(
        %__MODULE__{initialized?: false} = state,
        %Requests.Initialize{
          params: %Structures.InitializeParams{} = event
        }
      ) do
    client_name =
      case event.client_info do
        %{name: name} -> name
        _ -> nil
      end

    config = Configuration.new(event.root_uri, event.capabilities, client_name)
    new_state = %__MODULE__{state | configuration: config, initialized?: true}
    Logger.info("Starting project at uri #{config.project.root_uri}")

    response = initialize_result()

    Project.Supervisor.start(config.project)
    {:ok, response, new_state}
  end

  def initialize(%__MODULE__{initialized?: true}, %Requests.Initialize{}) do
    {:error, :already_initialized}
  end

  def default_configuration(%__MODULE__{configuration: config}) do
    Configuration.default(config)
  end

  def apply(%__MODULE__{initialized?: false}, request) do
    Logger.error("Received #{request.method} before server was initialized")
    {:error, :not_initialized}
  end

  def apply(%__MODULE__{shutdown_received?: true} = state, %Notifications.Exit{}) do
    Logger.warning("Received an Exit notification. Halting the server in 150ms")
    :timer.apply_after(50, System, :halt, [0])
    {:ok, state}
  end

  def apply(%__MODULE__{shutdown_received?: true}, request) do
    Logger.error("Received #{request.method} after shutdown. Ignoring")
    {:error, :shutting_down}
  end

  def apply(%__MODULE__{} = state, %Notifications.WorkspaceDidChangeConfiguration{} = event) do
    case Configuration.on_change(state.configuration, event) do
      {:ok, config} ->
        {:ok, %__MODULE__{state | configuration: config}}

      {:ok, config, request} ->
        GenLSP.request(Expert.get_lsp(), request)
        {:ok, %__MODULE__{state | configuration: config}}
    end

    {:ok, state}
  end

  def apply(%__MODULE__{} = state, %GenLSP.Notifications.TextDocumentDidChange{params: params}) do
    uri = params.text_document.uri
    version = params.text_document.version
    project = state.configuration.project

    case Document.Store.get_and_update(
           uri,
           # TODO: this function needs to accept the GenLSP data structure
           &Document.apply_content_changes(&1, version, params.content_changes)
         ) do
      {:ok, updated_source} ->
        updated_message =
          file_changed(
            uri: updated_source.uri,
            open?: true,
            from_version: version,
            to_version: updated_source.version
          )

        EngineApi.broadcast(project, updated_message)
        EngineApi.compile_document(state.configuration.project, updated_source)
        {:ok, state}

      error ->
        error
    end
  end

  def apply(%__MODULE__{} = state, %GenLSP.Notifications.TextDocumentDidOpen{} = did_open) do
    %GenLSP.Structures.TextDocumentItem{
      text: text,
      uri: uri,
      version: version,
      language_id: language_id
    } = did_open.params.text_document

    case Document.Store.open(uri, text, version, language_id) do
      :ok ->
        Logger.info("################### opened #{uri}")
        {:ok, state}

      error ->
        Logger.error("################## Could not open #{uri} #{inspect(error)}")
        error
    end
  end

  def apply(%__MODULE__{} = state, %GenLSP.Notifications.TextDocumentDidClose{params: params}) do
    uri = params.text_document.uri

    case Document.Store.close(uri) do
      :ok ->
        {:ok, state}

      error ->
        Logger.warning(
          "Received textDocument/didClose for a file that wasn't open. URI was #{uri}"
        )

        error
    end
  end

  def apply(%__MODULE__{} = state, %GenLSP.Notifications.TextDocumentDidSave{params: params}) do
    uri = params.text_document.uri

    case Document.Store.save(uri) do
      :ok ->
        EngineApi.schedule_compile(state.configuration.project, false)
        {:ok, state}

      error ->
        Logger.error("Save failed for uri #{uri} error was #{inspect(error)}")
        error
    end
  end

  def apply(%__MODULE__{} = state, %Notifications.Initialized{}) do
    Logger.info("Expert Initialized")
    {:ok, %__MODULE__{state | initialized?: true}}
  end

  def apply(%__MODULE__{} = state, %GenLSP.Requests.Shutdown{}) do
    Logger.info("Shutting down")

    {:ok, nil, %__MODULE__{state | shutdown_received?: true}}
  end

  def apply(%__MODULE__{} = state, %GenLSP.Notifications.WorkspaceDidChangeWatchedFiles{
        params: params
      }) do
    project = state.configuration.project

    Enum.each(params.changes, fn %GenLSP.Structures.FileEvent{} = change ->
      event = filesystem_event(project: Project, uri: change.uri, event_type: change.type)
      EngineApi.broadcast(project, event)
    end)

    {:ok, state}
  end

  def apply(%__MODULE__{} = state, msg) do
    Logger.error("Ignoring unhandled message: #{inspect(msg)}")
    {:ok, state}
  end

  def initialize_result do
    sync_options =
      %GenLSP.Structures.TextDocumentSyncOptions{
        open_close: true,
        change: GenLSP.Enumerations.TextDocumentSyncKind.incremental(),
        save: true
      }

    code_action_options =
      %GenLSP.Structures.CodeActionOptions{
        code_action_kinds: @supported_code_actions,
        resolve_provider: false
      }

    code_lens_options =
      %GenLSP.Structures.CodeLensOptions{resolve_provider: false}

    command_options =
      %GenLSP.Structures.ExecuteCommandOptions{commands: Handlers.Commands.names()}

    completion_options =
      %GenLSP.Structures.CompletionOptions{
        trigger_characters: CodeIntelligence.Completion.trigger_characters()
      }

    server_capabilities =
      %Structures.ServerCapabilities{
        code_action_provider: code_action_options,
        code_lens_provider: code_lens_options,
        completion_provider: completion_options,
        definition_provider: true,
        document_formatting_provider: true,
        document_symbol_provider: true,
        execute_command_provider: command_options,
        hover_provider: true,
        references_provider: true,
        text_document_sync: sync_options,
        workspace_symbol_provider: true
      }

    %GenLSP.Structures.InitializeResult{
      capabilities: server_capabilities,
      server_info: %{
        name: "Expert",
        version: "0.0.1"
      }
    }
  end
end
