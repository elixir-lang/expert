defmodule Expert.Provider.Handlers.CodeAction do
  @behaviour Expert.Provider.Handler

  alias Expert.ActiveProjects
  alias Expert.EngineApi
  alias Forge.CodeAction
  alias Forge.Project
  alias GenLSP.Requests
  alias GenLSP.Structures

  @impl Expert.Provider.Handler
  def handle(%Requests.TextDocumentCodeAction{params: %Structures.CodeActionParams{} = params}) do
    document = Forge.Document.Container.context_document(params, nil)
    projects = ActiveProjects.projects()
    project = Project.project_for_document(projects, document)
    diagnostics = Enum.map(params.context.diagnostics, &to_code_action_diagnostic/1)

    code_actions =
      EngineApi.code_actions(
        project,
        document,
        params.range,
        diagnostics,
        params.context.only || :all,
        params.context.trigger_kind
      )

    results = Enum.map(code_actions, &to_result/1)

    {:ok, results}
  end

  defp to_code_action_diagnostic(%Structures.Diagnostic{} = diagnostic) do
    %CodeAction.Diagnostic{
      range: diagnostic.range,
      message: diagnostic.message,
      source: diagnostic.source
    }
  end

  defp to_result(%CodeAction{} = action) do
    %Structures.CodeAction{
      title: action.title,
      kind: action.kind,
      edit: %Structures.WorkspaceEdit{changes: %{action.uri => action.changes}}
    }
  end
end
