defmodule Expert.State do
  alias Expert.ActiveProjects
  alias Expert.CodeIntelligence
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Expert.Project
  alias Expert.Provider.Handlers
  alias Forge.Document
  alias Forge.Project
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

    root_path = Document.Path.from_uri(event.root_uri)

    root_path
    |> Forge.Workspace.new()
    |> Forge.Workspace.set_workspace()

    config = Configuration.new(event.capabilities, client_name)
    new_state = %__MODULE__{state | configuration: config, initialized?: true}

    response = initialize_result()

    projects =
      for %{uri: uri} <- event.workspace_folders || [],
          project = Project.new(uri),
          project.mix_project? do
        project
      end

    ActiveProjects.set_projects(projects)

    for project <- projects do
      Task.Supervisor.start_child(:expert_task_queue, fn ->
        ensure_project_node_started(project)
      end)
    end

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

  def apply(%__MODULE__{} = state, %Notifications.WorkspaceDidChangeWorkspaceFolders{
        params: %Structures.DidChangeWorkspaceFoldersParams{
          event: %Structures.WorkspaceFoldersChangeEvent{added: added, removed: removed}
        }
      }) do
    removed_projects =
      for %{uri: uri} <- removed do
        project = Project.new(uri)

        stop_project_node(project)

        project
      end

    added_projects =
      for %{uri: uri} <- added do
        project = Project.new(uri)
        ensure_project_node_started(project)
        project
      end

    ActiveProjects.add_projects(added_projects)
    ActiveProjects.remove_projects(removed_projects)

    {:ok, state}
  end

  def apply(%__MODULE__{} = state, %GenLSP.Notifications.TextDocumentDidChange{params: params}) do
    uri = params.text_document.uri
    version = params.text_document.version
    projects = ActiveProjects.projects()
    project = Project.project_for_uri(projects, uri)

    with true <- ActiveProjects.active?(project),
         {:ok, updated_source} <-
           Document.Store.get_and_update(
             uri,
             # TODO: this function needs to accept the GenLSP data structure
             &Document.apply_content_changes(&1, version, params.content_changes)
           ) do
      updated_message =
        file_changed(
          uri: updated_source.uri,
          open?: true,
          from_version: version,
          to_version: updated_source.version
        )

      EngineApi.broadcast(project, updated_message)
      EngineApi.compile_document(project, updated_source)
      {:ok, state}
    else
      false ->
        GenLSP.info(
          Expert.get_lsp(),
          "Received request textDocument/didChange before engine for #{Project.name(project)} was initialized. Ignoring."
        )

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

    project =
      with nil <- Enum.find(ActiveProjects.projects(), &Project.within_project?(&1, uri)) do
        Project.find_project(uri)
      end

    if project do
      Task.Supervisor.start_child(:expert_task_queue, fn ->
        ensure_project_node_started(project)
      end)

      ActiveProjects.add_projects([project])
    end

    case Document.Store.open(uri, text, version, language_id) do
      :ok ->
        Logger.info("Opened #{uri}")

        {:ok, state}

      error ->
        Logger.error("Could not open #{uri} #{inspect(error)}")

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
    project = Forge.Project.project_for_uri(ActiveProjects.projects(), uri)

    case Document.Store.save(uri) do
      :ok ->
        EngineApi.schedule_compile(project, false)
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

  def apply(%__MODULE__{} = state, %Notifications.WorkspaceDidChangeWatchedFiles{params: params}) do
    for project <- ActiveProjects.projects(),
        change <- params.changes do
      params = filesystem_event(project: Project, uri: change.uri, event_type: change.type)
      EngineApi.broadcast(project, params)
    end

    {:ok, state}
  end

  def apply(%__MODULE__{} = state, msg) do
    Logger.error("Ignoring unhandled message: #{inspect(msg)}")
    {:ok, state}
  end

  defp ensure_project_node_started(project) do
    case Expert.Project.Supervisor.start(project) do
      {:ok, _pid} ->
        ActiveProjects.set_ready(project, true)
        Logger.info("Project node started for #{Project.name(project)}")

        GenLSP.log(Expert.get_lsp(), "Started project node for #{Project.name(project)}")

      {:error, {reason, pid}} when reason in [:already_started, :already_present] ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error(
          "Failed to start project node for #{Project.name(project)}: #{inspect(reason, pretty: true)}"
        )

        GenLSP.error(
          Expert.get_lsp(),
          "Failed to start project node for #{Project.name(project)}: #{inspect(reason, pretty: true)}"
        )

        {:error, reason}
    end
  end

  defp stop_project_node(project) do
    Expert.Project.Supervisor.stop(project)
    ActiveProjects.set_ready(project, false)

    GenLSP.log(
      Expert.get_lsp(),
      "Stopping project node for #{Project.name(project)}"
    )
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
        workspace_symbol_provider: true,
        workspace: %{
          workspace_folders: %Structures.WorkspaceFoldersServerCapabilities{
            supported: true,
            change_notifications: true
          }
        }
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
