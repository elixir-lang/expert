defmodule Expert.Provider.Handlers.FindReferences do
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Forge.Ast
  alias Forge.Document
  alias GenLSP.Requests.TextDocumentReferences
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def handle(
        %TextDocumentReferences{params: %Structures.ReferenceParams{} = params},
        %Context{} = context
      ) do
    %Context{document: document, project: project} = context
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
