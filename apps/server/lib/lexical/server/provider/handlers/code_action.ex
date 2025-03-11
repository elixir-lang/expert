defmodule Lexical.Server.Provider.Handlers.CodeAction do
  alias Lexical.Protocol.Requests
  alias Lexical.Protocol.Responses
  alias Lexical.Protocol.Types
  alias Lexical.Protocol.Types.Workspace
  alias Lexical.RemoteControl
  alias Lexical.RemoteControl.CodeAction
  alias Lexical.Server.Configuration

  require Logger

  def handle(%Requests.CodeAction{} = request, %Configuration{} = config) do
    diagnostics = Enum.map(request.context.diagnostics, &to_code_action_diagnostic/1)

    code_actions =
      RemoteControl.Api.code_actions(
        config.project,
        request.document,
        request.range,
        diagnostics,
        request.context.only || :all,
        request.context.trigger_kind
      )

    results = Enum.map(code_actions, &to_result/1)
    reply = Responses.CodeAction.new(request.id, results)

    {:reply, reply}
  end

  defp to_code_action_diagnostic(%Types.Diagnostic{} = diagnostic) do
    CodeAction.Diagnostic.new(diagnostic.range, diagnostic.message, diagnostic.source)
  end

  defp to_result(%CodeAction{} = action) do
    Types.CodeAction.new(
      title: action.title,
      kind: action.kind,
      edit: Workspace.Edit.new(changes: %{action.uri => action.changes})
    )
  end
end
