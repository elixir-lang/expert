defmodule Expert.Project.SearchListener do
  use GenServer

  import Forge.EngineApi.Messages

  alias Expert.EngineApi
  alias Expert.Protocol.Id
  alias Forge.Formats
  alias Forge.Project
  alias GenLSP.Requests

  require Logger

  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, [project], name: name(project))
  end

  defp name(%Project{} = project) do
    :"#{Project.unique_name(project)}::search_listener"
  end

  @impl GenServer
  def init([%Project{} = project]) do
    EngineApi.register_listener(project, self(), [
      project_reindex_requested(),
      project_reindexed(),
      search_store_loading()
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

  def handle_info(search_store_loading(), %Project{} = project) do
    message = "Search index is loading for #{Project.name(project)}..."
    Logger.info(message)

    GenLSP.notify(Expert.get_lsp(), %GenLSP.Notifications.WindowShowMessage{
      params: %GenLSP.Structures.ShowMessageParams{
        type: GenLSP.Enumerations.MessageType.info(),
        message: message
      }
    })

    {:noreply, project}
  end
end
