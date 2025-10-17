defmodule Expert.Provider.Handlers.GoToDefinition do
  alias Expert.ActiveProjects
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Forge.Project
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  def handle(
        %Requests.TextDocumentDefinition{
          params: %Structures.DefinitionParams{} = params
        },
        %Configuration{}
      ) do
    document = Forge.Document.Container.context_document(params, nil)
    projects = ActiveProjects.projects()
    project = Project.project_for_document(projects, document)

    case EngineApi.definition(project, document, params.position) do
      {:ok, native_location} ->
        {:ok, native_location}

      {:error, reason} ->
        Logger.error("GoToDefinition failed: #{inspect(reason)}")
        {:ok, nil}
    end
  end
end
