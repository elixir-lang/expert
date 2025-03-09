defmodule Lexical.RemoteControl.CodeAction.Handlers.Refactorex do
  alias Lexical.Document
  alias Lexical.Document.Changes
  alias Lexical.Document.Range
  alias Lexical.RemoteControl.CodeAction
  alias Lexical.RemoteControl.CodeMod.Diff
  alias Refactorex

  @behaviour CodeAction.Handler

  @impl CodeAction.Handler
  def actions(%Document{} = doc, %Range{} = range, _diagnostics) do
    with {:ok, target} <- line_or_selection(doc, range),
         # Could use AST.from/1 but it would lose comments inside Refactorex
         {:ok, ast} <- Sourceror.parse_string(Document.to_string(doc)) do
      ast
      |> Sourceror.Zipper.zip()
      |> Refactorex.Refactor.available_refactorings(target, true)
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

  defp line_or_selection(doc, %{start: start} = range) do
    [
      # new lines before the selection
      String.duplicate("\n", start.line - 1),
      # same line whitespace before the selection
      String.duplicate(" ", start.character - 1),
      # the selection
      Document.fragment(doc, range.start, range.end)
    ]
    |> IO.iodata_to_binary()
    |> Sourceror.parse_string()
  end

  defp map_kind("quickfix"), do: :quick_fix
  defp map_kind(kind), do: :"#{String.replace(kind, ".", "_")}"
end
