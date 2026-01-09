defmodule Expert.Provider.Handlers.Commands do
  @behaviour Expert.Provider.Handler

  alias Expert.ActiveProjects
  alias Expert.EngineApi
  alias Forge.Project
  alias GenLSP.Enumerations.ErrorCodes
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  @reindex_name "Reindex"

  def names do
    [@reindex_name]
  end

  def reindex_command(%Project{} = project) do
    project_name = Project.name(project)

    %Structures.Command{
      title: "Rebuild #{project_name}'s code search index",
      command: @reindex_name
    }
  end

  @impl Expert.Provider.Handler
  def handle(%Requests.WorkspaceExecuteCommand{
        params: %Structures.ExecuteCommandParams{} = params
      }) do
    projects = ActiveProjects.projects()

    response =
      case params.command do
        @reindex_name ->
          project_names = Enum.map_join(projects, ", ", &Project.name/1)
          Logger.info("Reindex #{project_names}")
          reindex_all(projects)

        invalid ->
          message = "#{invalid} is not a valid command"
          internal_error(message)
      end

    {:ok, response}
  end

  defp reindex_all(projects) do
    Enum.reduce_while(projects, :ok, fn project, _ ->
      case EngineApi.reindex(project) do
        :ok ->
          {:cont, "ok"}

        error ->
          GenLSP.notify(Expert.get_lsp(), %GenLSP.Notifications.WindowShowMessage{
            params: %GenLSP.Structures.ShowMessageParams{
              type: GenLSP.Enumerations.MessageType.error(),
              message: "Indexing #{Project.name(project)} failed"
            }
          })

          Logger.error("Indexing command failed due to #{inspect(error)}")

          {:halt, internal_error("Could not reindex: #{error}")}
      end
    end)
  end

  defp internal_error(message) do
    %GenLSP.ErrorResponse{code: ErrorCodes.internal_error(), message: message}
  end
end
