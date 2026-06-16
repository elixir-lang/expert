defmodule Engine.CodeAction.Handlers.Refactorex do
  @behaviour Engine.CodeAction.Handler

  alias Engine.CodeAction
  alias Engine.CodeMod
  alias Forge.Document
  alias Forge.Document.Changes
  alias Forge.Document.Range
  alias Forge.Refactor
  alias GenLSP.Enumerations

  require Logger

  @impl CodeAction.Handler
  def actions(%Document{} = doc, %Range{} = range, _diagnostics, opts \\ []) do
    with {:ok, target} <- line_or_selection(doc, range),
         {:ok, ast} <- Sourceror.parse_string(Document.to_string(doc)) do
      zipper = Sourceror.Zipper.zip(ast)
      refactorings = Refactor.list(zipper, target)

      if Keyword.get(opts, :defer_edits?, false) do
        Enum.map(refactorings, &to_deferred_action(doc, range, &1))
      else
        execute_all(doc, zipper, target, refactorings)
      end
    else
      _ -> []
    end
  rescue
    _ ->
      []
  end

  @doc """
  Computes the edits for a single refactoring previously listed with `defer_edits?: true`, as
  part of the `codeAction/resolve` flow.
  """
  @spec resolve(Document.t(), Range.t(), String.t()) :: {:ok, Changes.t()} | :error
  def resolve(%Document{} = doc, %Range{} = range, module_name) do
    with {:ok, target} <- line_or_selection(doc, range),
         {:ok, ast} <- Sourceror.parse_string(Document.to_string(doc)),
         {:ok, refactoring} <-
           ast |> Sourceror.Zipper.zip() |> Refactor.execute(target, module_name) do
      {:ok, ast_to_changes(doc, refactoring.refactored, sourceror_opts(doc))}
    else
      _ -> :error
    end
  end

  @impl CodeAction.Handler
  def kinds, do: [Enumerations.CodeActionKind.refactor()]

  @impl CodeAction.Handler
  def trigger_kind, do: :all

  defp to_deferred_action(%Document{} = doc, %Range{} = range, refactoring) do
    data = Forge.CodeAction.to_refactor_data(doc.uri, doc.version, range, refactoring.module)
    Forge.CodeAction.deferred(doc.uri, refactoring.title, refactoring.kind, data)
  end

  # Eager fallback for clients without codeAction/resolve support. The formatter
  # configuration depends only on the project and file, so it is resolved once
  # per request and shared across refactorings (and skipped entirely when none
  # apply, keeping the common empty case off the formatter lookup).
  defp execute_all(_doc, _zipper, _target, []), do: []

  defp execute_all(doc, zipper, target, refactorings) do
    sourceror_opts = sourceror_opts(doc)
    Enum.flat_map(refactorings, &execute_eagerly(doc, zipper, target, &1, sourceror_opts))
  end

  # Each refactoring is isolated: a broken rewrite loses that one action instead
  # of failing the whole codeAction request. Raises, throws, and exits are all
  # caught here so one misbehaving refactoring can't take down the listing.
  defp execute_eagerly(doc, zipper, target, refactoring, sourceror_opts) do
    case Refactor.execute(zipper, target, refactoring.module) do
      {:ok, executed} ->
        [
          Forge.CodeAction.new(
            doc.uri,
            executed.title,
            executed.kind,
            ast_to_changes(doc, executed.refactored, sourceror_opts)
          )
        ]

      :error ->
        []
    end
  rescue
    error ->
      Logger.error(
        "refactor: #{inspect(refactoring.module)}: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      []
  end

  defp line_or_selection(_, %{
         start: %{line: line, character: char},
         end: %{line: line, character: char}
       }),
       do: {:ok, line}

  defp line_or_selection(doc, %{start: start} = range) do
    doc
    |> Document.fragment(range.start, range.end)
    |> Sourceror.parse_string(line: start.line, column: start.character)
  end

  defp sourceror_opts(doc) do
    {formatter, opts} =
      case CodeMod.Format.Cache.fetch_formatter(Engine.get_project(), doc.path) do
        {:ok, formatter, opts} ->
          {formatter, opts}

        :error ->
          {&Code.format_string!/1, []}
      end

    Keyword.reject(
      [
        formatter: formatter,
        locals_without_parens: opts[:locals_without_parens] || [],
        line_length: opts[:line_length]
      ],
      fn {_k, v} -> is_nil(v) end
    )
  end

  defp ast_to_changes(doc, ast, sourceror_opts) do
    ast
    |> Sourceror.to_string(sourceror_opts)
    |> then(&CodeMod.Diff.diff(doc, &1))
    |> then(&Changes.new(doc, &1))
  end
end
