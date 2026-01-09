defmodule Expert.Provider.Handlers.FindReferences do
  @behaviour Expert.Provider.Handler

  alias Expert.ActiveProjects
  alias Expert.EngineApi
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Project
  alias GenLSP.Requests.TextDocumentReferences
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def handle(%TextDocumentReferences{params: %Structures.ReferenceParams{} = params}) do
    document = Forge.Document.Container.context_document(params, nil)
    projects = ActiveProjects.projects()
    project = Project.project_for_document(projects, document)
    include_declaration? = !!params.context.include_declaration

    locations =
      case Document.Store.fetch(document.uri, :analysis) do
        {:ok, _document, %Ast.Analysis{} = analysis} ->
          EngineApi.references(project, analysis, params.position, include_declaration?)

        _ ->
          nil
      end

    {:ok, locations}
  end
end
