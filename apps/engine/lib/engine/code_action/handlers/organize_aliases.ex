defmodule Engine.CodeAction.Handlers.OrganizeAliases do
  alias Engine.CodeAction
  alias Engine.CodeMod
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Scope
  alias Forge.Document
  alias Forge.Document.Changes
  alias Forge.Document.Range
  alias GenLSP.Enumerations.CodeActionKind

  require Logger

  @behaviour CodeAction.Handler

  @impl CodeAction.Handler
  def actions(%Document{} = doc, %Range{} = range, _diagnostics) do
    with {:ok, _doc, analysis} <- Document.Store.fetch(doc.uri, :analysis),
         :ok <- check_aliases(doc, analysis, range) do
      aliases = CodeMod.Aliases.in_scope(analysis, range)
      {insert_position, trailer} = CodeMod.Aliases.insert_position(analysis, range.start)
      edits = CodeMod.Aliases.to_edits(aliases, insert_position, trailer)

      if Enum.empty?(edits) do
        []
      else
        changes = Changes.new(doc, edits)

        [
          Forge.CodeAction.new(
            doc.uri,
            "Organize aliases",
            CodeActionKind.source_organize_imports(),
            changes
          )
        ]
      end
    else
      _ ->
        []
    end
  end

  @impl CodeAction.Handler
  def kinds do
    [CodeActionKind.source(), CodeActionKind.source_organize_imports()]
  end

  @impl CodeAction.Handler
  def trigger_kind, do: :all

  defp check_aliases(%Document{}, %Analysis{} = analysis, %Range{} = range) do
    case Analysis.module_scope(analysis, range) do
      %Scope{aliases: [_ | _]} -> :ok
      _ -> :error
    end
  end
end
