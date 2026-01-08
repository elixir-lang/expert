defmodule Engine.CodeMod.Directives do
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Edit
  alias Forge.Document.Position
  alias Forge.Document.Range

  alias Sourceror.Zipper

  @type render_fun :: (any -> String.t())
  @type sort_fun :: (any -> term())
  @type range_fun :: (any -> Range.t() | nil)

  @spec insert_position(Analysis.t(), Range.t(), list()) :: {Position.t(), String.t() | nil}
  def insert_position(%Analysis{} = analysis, %Range{} = range, current_items)
      when is_list(current_items) do
    do_insert_position(analysis, current_items, range)
  end

  @spec to_edits(list(), Position.t(), String.t() | nil, keyword()) :: [Edit.t()]
  def to_edits(items, %Position{} = insert_position, trailer \\ nil, opts) when is_list(items) do
    render_fun = Keyword.fetch!(opts, :render)
    sort_fun = Keyword.fetch!(opts, :sort_by)
    range_fun = Keyword.fetch!(opts, :range)

    do_to_edits(items, insert_position, trailer, render_fun, sort_fun, range_fun)
  end

  defp do_to_edits([], _, _, _, _, _), do: []

  defp do_to_edits(items, %Position{} = insert_position, trailer, render_fun, sort_fun, range_fun) do
    # Collect all ranges from original items BEFORE deduping
    # This ensures duplicate directives get their lines removed
    all_ranges =
      items
      |> Enum.map(&range_fun.(&1))
      |> Enum.reject(&is_nil/1)

    unique_items =
      items
      |> Enum.uniq_by(sort_fun)
      |> Enum.sort_by(sort_fun)

    initial_spaces = insert_position.character - 1

    block_text =
      unique_items
      |> Enum.map_join("\n", fn item ->
        item
        |> render_fun.()
        |> indent(initial_spaces)
      end)
      |> String.trim_trailing()

    zeroed = put_in(insert_position.character, 1)
    new_range = Range.new(zeroed, zeroed)

    block_text =
      if is_binary(trailer) do
        block_text <> trailer
      else
        block_text
      end

    edits = remove_old_directives(all_ranges)

    edits ++ [Edit.new(block_text, new_range)]
  end

  defp indent(text, spaces) do
    String.duplicate(" ", spaces) <> text
  end

  defp remove_old_directives(ranges) do
    ranges =
      ranges
      |> Enum.sort_by(& &1.start.line, :desc)
      |> Enum.uniq_by(& &1)
      |> Enum.map(fn %Range{} = range ->
        orig_range = range

        orig_range
        |> put_in([:start, :character], 1)
        |> update_in([:end], fn %Position{} = pos ->
          %Position{pos | character: 1, line: pos.line + 1}
        end)
      end)

    first_index = length(ranges) - 1

    ranges
    |> Enum.with_index()
    |> Enum.map(fn
      {range, ^first_index} ->
        Edit.new("\n", range)

      {range, _} ->
        Edit.new("", range)
    end)
    |> merge_adjacent_edits()
  end

  defp merge_adjacent_edits([]), do: []
  defp merge_adjacent_edits([_] = edit), do: edit

  defp merge_adjacent_edits([edit | rest]) do
    rest
    |> Enum.reduce([edit], fn %Edit{} = current, [%Edit{} = last | rest] = edits ->
      with {same_text, same_text} <- {last.text, current.text},
           {same, same} <- {to_tuple(current.range.end), to_tuple(last.range.start)} do
        collapsed = put_in(current.range.end, last.range.end)

        [collapsed | rest]
      else
        _ ->
          [current | edits]
      end
    end)
    |> Enum.reverse()
  end

  defp to_tuple(%Position{} = position) do
    {position.line, position.character}
  end

  defp do_insert_position(%Analysis{}, [_item | _] = items, _) do
    first = Enum.min_by(items, &{&1.range.start.line, &1.range.start.character})
    {first.range.start, nil}
  end

  defp do_insert_position(%Analysis{} = analysis, _, range) do
    case Analysis.module_scope(analysis, range) do
      %Forge.Ast.Analysis.Scope{id: :global} = scope ->
        {scope.range.start, "\n"}

      %Forge.Ast.Analysis.Scope{} = scope ->
        scope_start = scope.range.start

        initial_position =
          scope_start
          |> put_in([:line], scope_start.line + 1)
          |> put_in([:character], scope.range.end.character)
          |> constrain_to_range(scope.range)

        position =
          case Ast.zipper_at(analysis.document, scope_start) do
            {:ok, zipper} ->
              {_, position} =
                Zipper.traverse(zipper, initial_position, fn
                  %Zipper{node: {:@, _, [{:moduledoc, _, _}]}} = zipper, _acc ->
                    range = Sourceror.get_range(zipper.node)

                    {zipper, after_node(analysis.document, scope.range, range)}

                  zipper, acc ->
                    {zipper, acc}
                end)

              position

            _ ->
              initial_position
          end

        maybe_move_cursor_to_token_start(position, analysis)
    end
  end

  defp after_node(%Document{} = document, %Range{} = scope_range, %{
         start: start_pos,
         end: end_pos
       }) do
    document
    |> Position.new(end_pos[:line] + 1, start_pos[:column])
    |> constrain_to_range(scope_range)
  end

  defp constrain_to_range(%Position{} = position, %Range{} = scope_range) do
    cond do
      position.line == scope_range.end.line ->
        character = min(scope_range.end.character, position.character)
        %Position{position | character: character}

      position.line > scope_range.end.line ->
        %{scope_range.end | character: 1}

      true ->
        position
    end
  end

  defp maybe_move_cursor_to_token_start(%Position{} = position, %Analysis{} = analysis) do
    project = Engine.get_project()

    with {:ok, env} <- Ast.Env.new(project, analysis, position),
         false <- String.last(env.prefix) in [" ", ""] do
      non_empty_characters_count = env.prefix |> String.trim_leading() |> String.length()

      new_position = %Position{
        position
        | character: position.character - non_empty_characters_count
      }

      {new_position, "\n"}
    else
      _ ->
        {position, "\n"}
    end
  end
end
