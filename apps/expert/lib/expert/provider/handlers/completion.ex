defmodule Expert.Provider.Handlers.Completion do
  @behaviour Expert.Provider.Handler

  alias Expert.ActiveProjects
  alias Expert.CodeIntelligence
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Project
  alias GenLSP.Enumerations.CompletionTriggerKind
  alias GenLSP.Requests
  alias GenLSP.Structures
  alias GenLSP.Structures.CompletionContext

  @impl Expert.Provider.Handler
  def handle(%Requests.TextDocumentCompletion{params: %Structures.CompletionParams{} = params}) do
    document = Document.Container.context_document(params, nil)
    projects = ActiveProjects.projects()
    project = Project.project_for_document(projects, document)

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
