defmodule Expert.Provider.Handlers.Formatting do
  alias Expert.ActiveProjects
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Forge.Document.Changes
  alias Forge.Project
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  def handle(
        %Requests.TextDocumentFormatting{params: %Structures.DocumentFormattingParams{} = params},
        %Configuration{}
      ) do
    document = Forge.Document.Container.context_document(params, nil)
    projects = ActiveProjects.projects()
    project = Project.project_for_document(projects, document)

    case EngineApi.format(project, document) do
      {:ok, %Changes{} = document_edits} ->
        {:ok, document_edits}

      {:error, reason} ->
        Logger.error("Formatter failed #{inspect(reason)}")
        {:ok, nil}
    end
  end
end
