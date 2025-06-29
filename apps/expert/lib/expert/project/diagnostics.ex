defmodule Expert.Project.Diagnostics do
  alias Expert.EngineApi
  alias Expert.Project.Diagnostics.State
  alias Forge.EngineApi.Messages
  alias Forge.Formats
  alias Forge.Project
  alias GenLSP.Notifications.TextDocumentPublishDiagnostics
  alias GenLSP.Structures

  import Messages
  require Logger
  use GenServer

  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, [project], name: name(project))
  end

  def child_spec(%Project{} = project) do
    %{
      id: {__MODULE__, Project.name(project)},
      start: {__MODULE__, :start_link, [project]}
    }
  end

  # GenServer callbacks

  @impl GenServer
  def init([%Project{} = project]) do
    EngineApi.register_listener(project, self(), [
      file_diagnostics(),
      project_compile_requested(),
      project_compiled(),
      project_diagnostics()
    ])

    state = State.new(project)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(project_compile_requested(), %State{} = state) do
    state = State.clear_all_flushed(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        project_diagnostics(build_number: build_number, diagnostics: diagnostics),
        %State{} = state
      ) do
    state =
      Enum.reduce(diagnostics, state, fn diagnostic, state ->
        State.add(state, build_number, diagnostic)
      end)

    publish_diagnostics(state)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        file_diagnostics(uri: uri, build_number: build_number, diagnostics: diagnostics),
        %State{} = state
      ) do
    state =
      case diagnostics do
        [] ->
          State.clear(state, uri)

        diagnostics ->
          Enum.reduce(diagnostics, state, fn diagnostic, state ->
            State.add(state, build_number, diagnostic)
          end)
      end

    publish_diagnostics(state)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        project_compiled(elapsed_ms: elapsed_ms),
        %State{} = state
      ) do
    project_name = Project.name(state.project)
    Logger.info("Compiled #{project_name} in #{Formats.time(elapsed_ms, unit: :millisecond)}")

    {:noreply, state}
  end

  # Private

  defp publish_diagnostics(%State{} = state) do
    Enum.each(state.entries_by_uri, fn {uri, %State.Entry{} = entry} ->
      with {:ok, diagnostics} <-
             entry |> State.Entry.diagnostics() |> Forge.Protocol.Convert.to_lsp() do
        GenLSP.notify(Expert.get_lsp(), %TextDocumentPublishDiagnostics{
          params: %Structures.PublishDiagnosticsParams{uri: uri, diagnostics: diagnostics}
        })
      end
    end)
  end

  defp name(%Project{} = project) do
    :"#{Project.name(project)}::diagnostics"
  end
end
