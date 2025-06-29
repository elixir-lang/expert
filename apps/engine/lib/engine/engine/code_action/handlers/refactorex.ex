defmodule Engine.CodeAction.Handlers.Refactorex do
  alias Engine.CodeAction
  alias Engine.CodeMod
  alias Forge.Document
  alias Forge.Document.Changes
  alias Forge.Document.Range
  alias GenLSP.Enumerations
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
        Forge.CodeAction.new(
          doc.uri,
          refactoring.title,
          refactoring.kind,
          ast_to_changes(doc, refactoring.refactored)
        )
      end)
    else
      _ -> []
    end
  end

  @impl CodeAction.Handler
  def kinds, do: [Enumerations.CodeActionKind.refactor()]

  @impl CodeAction.Handler
  def trigger_kind, do: Enumerations.CodeActionTriggerKind.invoked()

  defp line_or_selection(_, %{start: start, end: start}), do: {:ok, start.line}

  defp line_or_selection(doc, %{start: start} = range) do
    doc
    |> Document.fragment(range.start, range.end)
    |> Sourceror.parse_string(line: start.line, column: start.character)
  end

  defp ast_to_changes(doc, ast) do
    {formatter, opts} = CodeMod.Format.formatter_for_file(Engine.get_project(), doc.uri)

    ast
    |> Sourceror.to_string(
      formatter: formatter,
      locals_without_parens: opts[:locals_without_parens] || []
    )
    |> then(&CodeMod.Diff.diff(doc, &1))
    |> then(&Changes.new(doc, &1))
  end
end
