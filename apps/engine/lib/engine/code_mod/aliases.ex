defmodule Engine.CodeMod.Aliases do
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Alias
  alias Forge.Ast.Analysis.Scope
  alias Forge.Document
  alias Forge.Document.Edit
  alias Forge.Document.Position
  alias Forge.Document.Range

  alias Sourceror.Zipper

  @doc """
  Returns the aliases that are in scope at the given range.
  """
  @spec in_scope(Analysis.t(), Range.t()) :: [Alias.t()]
  def in_scope(%Analysis{} = analysis, %Range{} = range) do
    analysis
    |> Analysis.module_scope(range)
    |> aliases_in_scope()
  end

  @doc """
  Sorts the given aliases according to our rules
  """
  @spec sort(Enumerable.t(Alias.t())) :: [Alias.t()]
  def sort(aliases) do
    Enum.sort_by(aliases, fn %Alias{} = scope_alias ->
      Enum.map(scope_alias.module, fn elem -> elem |> to_string() |> String.downcase() end)
    end)
  end

  @doc """
  Returns the position in the document where aliases should be inserted
  Since a document can have multiple module definitions, the cursor position is used to
  determine the initial starting point.

  This function also returns a string that should be appended to the end of the
  edits that are performed.
  """
  @spec insert_position(Analysis.t(), Position.t()) :: {Position.t(), String.t() | nil}
  def insert_position(%Analysis{} = analysis, %Position{} = cursor_position) do
    range = Range.new(cursor_position, cursor_position)
    current_aliases = in_scope(analysis, range)
    do_insert_position(analysis, current_aliases, range)
  end

  @doc """
  Turns a list of aliases into aliases into edits
  """
  @spec to_edits([Alias.t()], Position.t(), trailer :: String.t() | nil) :: [Edit.t()]

  def to_edits(aliases, position, trailer \\ nil)
  def to_edits([], _, _), do: []

  def to_edits(aliases, %Position{} = insert_position, trailer) do
    aliases = sort(aliases)
    initial_spaces = insert_position.character - 1

    alias_text =
      aliases
      # get rid of duplicate aliases
      |> Enum.uniq_by(& &1.module)
      |> Enum.map_join("\n", fn %Alias{} = a ->
        text =
          if List.last(a.module) == a.as do
            "alias #{join(a.module)}"
          else
            "alias #{join(a.module)}, as: #{join(List.wrap(a.as))}"
          end

        indent(text, initial_spaces)
      end)
      |> String.trim_trailing()

    zeroed = put_in(insert_position.character, 1)
    new_alias_range = Range.new(zeroed, zeroed)

    alias_text =
      if is_binary(trailer) do
        alias_text <> trailer
      else
        alias_text
      end

    edits = remove_old_aliases(aliases)

    edits ++
      [Edit.new(alias_text, new_alias_range)]
  end

  defp aliases_in_scope(%Scope{} = scope) do
    scope.aliases
    |> Enum.filter(fn %Alias{} = scope_alias ->
      scope_alias.explicit? and Range.contains?(scope.range, scope_alias.range.start)
    end)
    |> sort()
  end

  defp join(module) do
    Enum.join(module, ".")
  end

  defp indent(text, spaces) do
    String.duplicate(" ", spaces) <> text
  end

  defp remove_old_aliases(aliases) do
    ranges =
      aliases
      # Reject new aliases that don't have a range
      |> Enum.reject(&is_nil(&1.range))
      # iterating back to start means we won't have prior edits
      # clobber subsequent edits
      |> Enum.sort_by(& &1.range.start.line, :desc)
      |> Enum.uniq_by(& &1.range)
      |> Enum.map(fn %Alias{} = alias ->
        orig_range = alias.range

        orig_range
        |> put_in([:start, :character], 1)
        |> update_in([:end], fn %Position{} = pos ->
          %Position{pos | character: 1, line: pos.line + 1}
        end)
      end)

    first_alias_index = length(ranges) - 1

    ranges
    |> Enum.with_index()
    |> Enum.map(fn
      {range, ^first_alias_index} ->
        # add a new line where the first alias was to make space
        # for the rewritten aliases
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

  defp do_insert_position(%Analysis{}, [%Alias{} | _] = aliases, _) do
    first = Enum.min_by(aliases, &{&1.range.start.line, &1.range.start.character})
    {first.range.start, nil}
  end

  defp do_insert_position(%Analysis{} = analysis, _, range) do
    case Analysis.module_scope(analysis, range) do
      %Scope{id: :global} = scope ->
        {scope.range.start, "\n"}

      %Scope{} = scope ->
        scope_start = scope.range.start
        # we use the end position here because the start position is right after
        # the do for modules, which puts it well into the line. The end position
        # is before the end, which is equal to the indent of the scope.

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
                    # If we detect a moduledoc node, place the alias after it
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
      # `  en|d` -> `2`
      # `en|d` -> `2`
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
