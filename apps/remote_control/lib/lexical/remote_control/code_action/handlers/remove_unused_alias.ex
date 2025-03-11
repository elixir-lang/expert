defmodule Lexical.RemoteControl.CodeAction.Handlers.RemoveUnusedAlias do
  @moduledoc """
  A code action that removes an unused alias

  Most of the code actions are fairly straightforward, but I think this one deserves a couple of comments on
  the approach. I initially tried the following:

    * Finding the alias via Sourceror's Zipper.find
    * Rewriting the ast via Macro.prewalk / postwalk
    * Using Macro.travesrse where I'd mark the metadata as being deleted in the prewalker, and
      delete it in the postwalker.

  They had the following problems.
  Sourceror would consistently produce ast that was not recognized by elixir 1.14's code normalizer, causing a crash.
  Using AST rewriting was susceptible to infinite recursion, and it was extremely difficult to delete blocks reliably.
  Blocks in one context would be deleted, but with a different formulation, nils would appear in the output code.
  It was also very difficult to pop up the stack and delete an entire multiple alias without zippers.

  So the approach we have here utilizes a hybrid of AST walking / text replacement. It works for all the examples
  I could come up with, but it's a bit longer than I desired. Dorgan said he'd take a look at the errors in the
  normalizer and possibly fix sourceror, so until then, this is what we have.
  """

  alias Lexical.Ast
  alias Lexical.Ast.Analysis
  alias Lexical.Document
  alias Lexical.Document.Changes
  alias Lexical.Document.Edit
  alias Lexical.Document.Position
  alias Lexical.Document.Range
  alias Lexical.RemoteControl.Analyzer
  alias Lexical.RemoteControl.CodeAction
  alias Lexical.RemoteControl.CodeAction.Diagnostic
  alias Sourceror.Zipper

  import Record

  defrecordp :multi_alias_metadata, [
    :document,
    :multi_alias_range,
    :removed_alias_range,
    :alias_count
  ]

  defrecordp :single_alias_metadata, [:document, :range]
  @behaviour CodeAction.Handler

  @impl CodeAction.Handler
  def actions(%Document{} = document, %Range{} = range, diagnostics) do
    Enum.reduce(diagnostics, [], fn %Diagnostic{} = diagnostic, acc ->
      case to_edit(document, range.start, diagnostic) do
        {:ok, module_name, edit} ->
          changes = Changes.new(document, [edit])
          action = CodeAction.new(document.uri, "Remove alias #{module_name}", :source, changes)

          [action | acc]

        _ ->
          acc
      end
    end)
  end

  @impl CodeAction.Handler
  def kinds, do: [:source]

  @impl CodeAction.Handler
  def trigger_kind, do: :all

  defp to_edit(%Document{} = document, %Position{} = position, %Diagnostic{} = diagnostic) do
    with {:ok, module_string} <- fetch_unused_alias_module_string(diagnostic),
         {:ok, _doc, %Analysis{} = analysis} <- Document.Store.fetch(document.uri, :analysis),
         last_segment = String.to_atom(module_string),
         {:ok, full_alias} <- fetch_full_alias(analysis, position, last_segment),
         {:ok, alias_meta} <- fetch_alias_metadata(position, analysis, full_alias, last_segment),
         {:ok, edit} <- fetch_edit(alias_meta) do
      {:ok, module_string, edit}
    else
      _ ->
        :error
    end
  end

  @alias_regex ~r/unused alias (\w+)/
  defp fetch_unused_alias_module_string(%Diagnostic{} = diagnostic) do
    case Regex.scan(@alias_regex, diagnostic.message) do
      [[_, module_string]] -> {:ok, module_string}
      _ -> :error
    end
  end

  defp fetch_alias_metadata(
         %Position{} = cursor,
         %Analysis{} = analysis,
         full_alias,
         last_segment
       ) do
    zipper = Zipper.zip(analysis.ast)
    document = analysis.document

    with :error <- find_single_alias(document, cursor, zipper, full_alias, last_segment) do
      find_multi_alias(document, cursor, zipper, last_segment)
    end
  end

  defp find_single_alias(
         %Document{} = document,
         %Position{} = cursor,
         %Zipper{} = zipper,
         full_alias,
         last_segment
       ) do
    finder = fn
      {:alias, _, [{:__aliases__, _, ^full_alias}]} = node ->
        Ast.contains_position?(node, cursor)

      {:alias, _,
       [
         {:__aliases__, _, ^full_alias},
         [{{:__block__, _, [:as]}, {:__aliases__, _, [^last_segment]}}]
       ]} = node ->
        Ast.contains_position?(node, cursor)

      _ ->
        false
    end

    case Zipper.find(zipper, finder) do
      nil ->
        :error

      %Zipper{node: node} ->
        metadata =
          single_alias_metadata(document: document, range: Ast.Range.fetch!(node, document))

        {:ok, metadata}
    end
  end

  defp find_multi_alias(
         %Document{} = document,
         %Position{} = cursor,
         %Zipper{} = zipper,
         last_segment
       ) do
    finder = fn
      {:alias, _, [{{:., _, _}, _, multi_alias_list}]} = node ->
        Enum.find_value(multi_alias_list, &segment_matches?(&1, last_segment)) and
          Ast.contains_position?(node, cursor)

      _ ->
        false
    end

    case Zipper.find(zipper, finder) do
      nil ->
        :error

      %Zipper{node: {:alias, _, [{{:., _, _}, _, multi_alias_list}]}} = zipper ->
        alias_node = Enum.find(multi_alias_list, &segment_matches?(&1, last_segment))

        multi_alias =
          multi_alias_metadata(
            document: document,
            multi_alias_range: Ast.Range.fetch!(zipper.node, document),
            removed_alias_range: Ast.Range.fetch!(alias_node, document),
            alias_count: length(multi_alias_list)
          )

        {:ok, multi_alias}
    end
  end

  defp fetch_full_alias(%Analysis{} = analysis, %Position{} = position, last_segment) do
    aliases = Analyzer.aliases_at(analysis, position)

    with {:ok, aliased_module} <- Map.fetch(aliases, last_segment),
         {:elixir, full_alias} <- Ast.Module.safe_split(aliased_module, as: :atoms) do
      {:ok, full_alias}
    end
  end

  defp segment_matches?({:__aliases__, _, segments}, last_segment) do
    List.last(segments) == last_segment
  end

  defp segment_matches?(_, _), do: false

  defp fetch_edit(single_alias_metadata(range: %Range{} = range)) do
    updated_range =
      range
      |> put_in([:start, :character], 1)
      |> include_next_line()

    {:ok, Edit.new("", updated_range)}
  end

  defp fetch_edit(multi_alias_metadata(alias_count: 1, multi_alias_range: range)) do
    # we're removing the last alias, so we can remove the entire thing.
    {:ok, Edit.new("", range)}
  end

  defp fetch_edit(
         multi_alias_metadata(
           document: %Document{} = document,
           removed_alias_range: %Range{} = range
         )
       ) do
    current_line = line_text(document, range.start.line)
    previous_line = line_text(document, range.start.line - 1)

    {range, edit_text} =
      if not String.ends_with?(current_line, ",") and String.ends_with?(previous_line, ",") do
        # delete the previous line's comma
        range = %Range{
          range
          | start: Position.new(document, range.start.line - 1, String.length(previous_line))
        }

        {range, "\n"}
      else
        {put_in(range.start.character, 1), ""}
      end

    {:ok, Edit.new(edit_text, include_next_line(range))}
  end

  defp fetch_edit(_), do: :error

  defp line_text(%Document{} = document, line_number) do
    case Document.fetch_text_at(document, line_number) do
      {:ok, line_text} -> line_text
      _ -> ""
    end
  end

  defp include_next_line(%Range{} = range) do
    update_in(range.end, fn old_position ->
      %Position{
        old_position
        | line: old_position.line + 1,
          character: 1
      }
    end)
  end
end
