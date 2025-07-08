defmodule Expert.Project.SearchListener do
  alias Expert.EngineApi
  alias Expert.Protocol.Id
  alias Forge.Formats
  alias Forge.Project
  alias GenLSP.Requests

  import Forge.EngineApi.Messages

  use GenServer
  require Logger

  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, [project], name: name(project))
  end

  defp name(%Project{} = project) do
    :"#{Project.name(project)}::search_listener"
  end

  @impl GenServer
  def init([%Project{} = project]) do
    EngineApi.register_listener(project, self(), [
      project_reindex_requested(),
      project_reindexed()
    ])

    {:ok, project}
  end

  @impl GenServer
  def handle_info(project_reindex_requested(), %Project{} = project) do
    Logger.info("project reindex requested")
    GenLSP.request(Expert.get_lsp(), %Requests.WorkspaceCodeLensRefresh{id: Id.next()})

    {:noreply, project}
  end

  def handle_info(project_reindexed(elapsed_ms: elapsed), %Project{} = project) do
    message = "Reindexed #{Project.name(project)} in #{Formats.time(elapsed, unit: :millisecond)}"
    Logger.info(message)
    GenLSP.request(Expert.get_lsp(), %Requests.WorkspaceCodeLensRefresh{id: Id.next()})

    GenLSP.notify(Expert.get_lsp(), %GenLSP.Notifications.WindowShowMessage{
      params: %GenLSP.Structures.ShowMessageParams{
        type: GenLSP.Enumerations.MessageType.info(),
        message: message
      }
    })

    {:noreply, project}
  end
end
