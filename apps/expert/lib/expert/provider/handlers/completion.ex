defmodule Expert.Provider.Handlers.Completion do
  @behaviour Expert.Provider.Handler

  alias Expert.CodeIntelligence
  alias Expert.Document.Context
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Document.Position
  alias GenLSP.Enumerations.CompletionTriggerKind
  alias GenLSP.Requests
  alias GenLSP.Structures
  alias GenLSP.Structures.CompletionContext

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentCompletion{params: %Structures.CompletionParams{} = params},
        %Context{} = context
      ) do
    %Context{document: document, project: project} = context

    completions =
      CodeIntelligence.Completion.complete(
        project,
        document_analysis(document, params.position),
        params.position,
        params.context || %CompletionContext{trigger_kind: CompletionTriggerKind.invoked()}
      )

    {:ok, completions}
  end

  defp document_analysis(%Document{} = document, %Position{} = position) do
    case Document.Store.fetch(document.uri, :analysis) do
      {:ok, %Document{}, %Ast.Analysis{} = analysis} ->
        Ast.reanalyze_to(analysis, position)

      _ ->
        document
        |> Ast.analyze()
        |> Ast.reanalyze_to(position)
    end
  end
end
