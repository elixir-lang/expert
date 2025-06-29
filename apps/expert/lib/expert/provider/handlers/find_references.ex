defmodule Expert.Provider.Handlers.FindReferences do
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Forge.Ast
  alias Forge.Document
  alias GenLSP.Requests.TextDocumentReferences
  alias GenLSP.Structures

  require Logger

  def handle(
        %TextDocumentReferences{params: %Structures.ReferenceParams{} = params},
        %Configuration{} = config
      ) do
    document = Forge.Document.Container.context_document(params, nil)
    include_declaration? = !!params.context.include_declaration

    locations =
      case Document.Store.fetch(document.uri, :analysis) do
        {:ok, _document, %Ast.Analysis{} = analysis} ->
          EngineApi.references(config.project, analysis, params.position, include_declaration?)

        _ ->
          nil
      end

    {:ok, locations}
  end
end
