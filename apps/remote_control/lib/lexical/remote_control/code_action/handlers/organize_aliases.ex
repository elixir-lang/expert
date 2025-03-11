defmodule Lexical.RemoteControl.CodeAction.Handlers.OrganizeAliases do
  alias Lexical.Ast.Analysis
  alias Lexical.Ast.Analysis.Scope
  alias Lexical.Document
  alias Lexical.Document.Changes
  alias Lexical.Document.Range
  alias Lexical.RemoteControl.CodeAction
  alias Lexical.RemoteControl.CodeMod

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
        [CodeAction.new(doc.uri, "Organize aliases", :source_organize_imports, changes)]
      end
    else
      _ -> []
    end
  end

  @impl CodeAction.Handler
  def kinds, do: [:source, :source_organize_imports]

  @impl CodeAction.Handler
  def trigger_kind, do: :all

  defp check_aliases(%Document{}, %Analysis{} = analysis, %Range{} = range) do
    case Analysis.module_scope(analysis, range) do
      %Scope{aliases: [_ | _]} -> :ok
      _ -> :error
    end
  end
end
