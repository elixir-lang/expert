defmodule Lexical.RemoteControl.CodeAction.Handlers.Refactorex do
  alias Lexical.Document
  alias Lexical.Document.Changes
  alias Lexical.Document.Range

  alias Lexical.RemoteControl
  alias Lexical.RemoteControl.CodeAction
  alias Lexical.RemoteControl.CodeMod

  alias Refactorex.Refactor

  @behaviour CodeAction.Handler

  @impl CodeAction.Handler
  def actions(%Document{} = doc, %Range{} = range, _diagnostics) do
    with {:ok, target} <- line_or_selection(doc, range),
         {:ok, ast} <- Sourceror.parse_string(Document.to_string(doc)) do
      ast
      |> Sourceror.Zipper.zip()
      |> Refactor.available_refactorings(target, true)
      |> Enum.map(fn refactoring ->
        CodeAction.new(
          doc.uri,
          refactoring.title,
          map_kind(refactoring.kind),
          ast_to_changes(doc, refactoring.refactored)
        )
      end)
    else
      _ -> []
    end
  end

  @impl CodeAction.Handler
  def kinds, do: [:refactor]

  @impl CodeAction.Handler
  def trigger_kind, do: :invoked

  defp line_or_selection(_, %{start: start, end: start}), do: {:ok, start.line}

  defp line_or_selection(doc, %{start: start} = range) do
    doc
    |> Document.fragment(range.start, range.end)
    |> Sourceror.parse_string(line: start.line, column: start.character)
  end

  defp map_kind("quickfix"), do: :quick_fix
  defp map_kind(kind), do: :"#{String.replace(kind, ".", "_")}"

  defp ast_to_changes(doc, ast) do
    {formatter, opts} = CodeMod.Format.formatter_for_file(RemoteControl.get_project(), doc.uri)

    ast
    |> Sourceror.to_string(
      formatter: formatter,
      locals_without_parens: opts[:locals_without_parens] || []
    )
    |> then(&CodeMod.Diff.diff(doc, &1))
    |> then(&Changes.new(doc, &1))
  end
end
