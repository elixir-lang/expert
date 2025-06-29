defmodule Expert.Provider.Handlers.Commands do
  alias Expert.Configuration
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

  def handle(
        %Requests.WorkspaceExecuteCommand{params: %Structures.ExecuteCommandParams{} = params},
        %Configuration{} = config
      ) do
    response =
      case params.command do
        @reindex_name ->
          Logger.info("Reindex #{Project.name(config.project)}")
          reindex(config.project)

        invalid ->
          message = "#{invalid} is not a valid command"
          internal_error(message)
      end

    {:reply, response}
  end

  defp reindex(%Project{} = project) do
    case EngineApi.reindex(project) do
      :ok ->
        {:ok, "ok"}

      error ->
        GenLSP.notify(Expert.get_lsp(), %GenLSP.Notifications.WindowShowMessage{
          params: %GenLSP.Structures.ShowMessageParams{
            type: GenLSP.Enumerations.MessageType.error(),
            message: "Indexing #{Project.name(project)} failed"
          }
        })

        Logger.error("Indexing command failed due to #{inspect(error)}")

        {:ok, internal_error("Could not reindex: #{error}")}
    end
  end

  defp internal_error(message) do
    %GenLSP.ErrorResponse{code: ErrorCodes.internal_error(), message: message}
  end
end
