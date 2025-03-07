defmodule Lexical.RemoteControl.CodeAction.Handlers.Refactorex do
  alias Lexical.Ast
  alias Lexical.Document
  alias Lexical.Document.Changes
  alias Lexical.Document.Range
  alias Lexical.RemoteControl.CodeAction
  alias Lexical.RemoteControl.CodeMod.Diff
  alias Refactorex.Refactor

  @behaviour CodeAction.Handler

  @impl CodeAction.Handler
  def actions(%Document{} = doc, %Range{} = range, _diagnostics) do
    # Could use Ast.from/1 or Ast.zipper_at/2 but both
    # of them would lose comments inside Refactorex
    with {:ok, ast} <- Sourceror.parse_string(Document.to_string(doc)),
         {:ok, target} <- line_or_selection(doc, range) do
      ast
      |> Sourceror.Zipper.zip()
      |> Refactor.available_refactorings(target, true)
      |> Enum.map(fn refactoring ->
        CodeAction.new(
          doc.uri,
          refactoring.title,
          map_kind(refactoring.kind),
          Changes.new(doc, Diff.diff(doc, refactoring.refactored))
        )
      end)
    else
      _ -> []
    end
  end

  @impl CodeAction.Handler
  def kinds, do: [:refactor]

  defp line_or_selection(_, %{start: start, end: start}), do: {:ok, start.line}
  defp line_or_selection(doc, range), do: Ast.Range.subtree(doc, range)

  defp map_kind("quickfix"), do: :quick_fix
  defp map_kind(kind), do: :"#{String.replace(kind, ".", "_")}"
end
