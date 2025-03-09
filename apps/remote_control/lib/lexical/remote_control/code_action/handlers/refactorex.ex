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
    original = Document.to_string(doc)

    range = update_in(range.start.line, &(&1 - 1))
    range = update_in(range.start.character, &(&1 - 1))
    range = update_in(range.end.line, &(&1 - 1))
    range = update_in(range.end.character, &(&1 - 1))

    case Refactorex.Parser.parse_inputs(original, range) do
      {:ok, zipper, selection_or_line} ->
        zipper
        |> Refactorex.Refactor.available_refactorings(selection_or_line, true)
        |> Enum.map(fn refactoring ->
          CodeAction.new(
            doc.uri,
            refactoring.title,
            map_kind(refactoring.kind),
            Changes.new(doc, Diff.diff(doc, refactoring.refactored))
          )
        end)

      {:error, :parse_error} ->
        []
    end
  end

  @impl CodeAction.Handler
  def kinds, do: [:refactor]

  defp map_kind("quickfix"), do: :quick_fix
  defp map_kind(kind), do: :"#{String.replace(kind, ".", "_")}"
end
