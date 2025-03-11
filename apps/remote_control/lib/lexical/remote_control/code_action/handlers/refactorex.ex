defmodule Lexical.RemoteControl.CodeAction.Handlers.Refactorex do
  alias Lexical.Document
  alias Lexical.Document.Changes
  alias Lexical.Document.Range
  alias Lexical.RemoteControl
  alias Lexical.RemoteControl.CodeAction
  alias Lexical.RemoteControl.CodeMod
  alias Refactorex.Refactor
  alias String

  @behaviour CodeAction.Handler

  require Logger

  @impl CodeAction.Handler
  def actions(%Document{} = doc, %Range{} = range, _diagnostics) do
    with {:ok, target} <- line_or_selection(doc, range),
         {:ok, ast} <- Sourceror.parse_string(Document.to_string(doc)) do
      Logger.info("[RefactorEx] target #{inspect(target)}")

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
      error ->
        Logger.error("[RefactorEx] error #{inspect(error)}")
        []
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

  defp ast_to_changes(doc, ast) do
    {formatter, opts} = CodeMod.Format.formatter_for_file(RemoteControl.get_project(), doc.uri)

    extract_comments_opts = [collapse_comments: true, correct_lines: true] ++ opts
    {ast, comments} = Sourceror.Comments.extract_comments(ast, extract_comments_opts)

    ast
    |> Code.quoted_to_algebra(
      local_without_parens: opts[:local_without_parens],
      comments: comments,
      escape: false
    )
    |> Inspect.Algebra.format(:infinity)
    |> IO.iodata_to_binary()
    |> formatter.()
    |> then(&Changes.new(doc, CodeMod.Diff.diff(doc, &1)))
  end
end
