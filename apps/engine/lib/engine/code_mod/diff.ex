defmodule Engine.CodeMod.Diff do
  alias Forge.CodeUnit
  alias Forge.Document
  alias Forge.Document.Edit
  alias Forge.Document.Position
  alias Forge.Document.Range

  @spec diff(Document.t(), String.t()) :: [Edit.t()]
  def diff(%Document{} = document, dest) when is_binary(dest) do
    document
    |> Document.to_string()
    |> String.myers_difference(dest)
    |> to_edits(document)
  end

  defp to_edits(difference, %Document{} = document) do
    {_, {current_line, prev_lines}} =
      Enum.reduce(difference, {{starting_line(), starting_character()}, {[], []}}, fn
        {diff_type, diff_string}, {position, edits} ->
          apply_diff(diff_type, position, diff_string, edits, document)
      end)

    [current_line | prev_lines]
    |> Enum.flat_map(fn line_edits ->
      line_edits
      |> Enum.reduce([], &collapse/2)
      |> Enum.reverse()
    end)
  end

  # This collapses a delete and an an insert that are adjacent to one another
  # into a single insert, changing the delete to insert the text from the
  # insert rather than ""
  # It's a small optimization, but it was in the original
  defp collapse(
         %Edit{
           text: "",
           range: %Range{
             end: %Position{character: same_character, line: same_line}
           }
         } = delete_edit,
         [
           %Edit{
             text: insert_text,
             range:
               %Range{
                 start: %Position{character: same_character, line: same_line}
               } = _insert_edit
           }
           | rest
         ]
       )
       when byte_size(insert_text) > 0 do
    collapsed_edit = %Edit{delete_edit | text: insert_text}
    [collapsed_edit | rest]
  end

  defp collapse(%Edit{} = edit, edits) do
    [edit | edits]
  end

  defp apply_diff(:eq, position, doc_string, edits, _document) do
    advance(doc_string, position, edits)
  end

  defp apply_diff(:del, {line, code_unit} = position, change, edits, document) do
    {after_pos, {current_line, prev_lines}} = advance(change, position, edits)
    {edit_end_line, edit_end_unit} = after_pos

    current_line = [
      edit(document, "", line, code_unit, edit_end_line, edit_end_unit) | current_line
    ]

    {after_pos, {current_line, prev_lines}}
  end

  defp apply_diff(
         :ins,
         {line, code_unit} = position,
         change,
         {current_line, prev_lines},
         document
       ) do
    current_line = [edit(document, change, line, code_unit, line, code_unit) | current_line]
    {position, {current_line, prev_lines}}
  end

  defp advance(<<>>, position, edits) do
    {position, edits}
  end

  for ending <- ["\r\n", "\r", "\n"] do
    defp advance(<<unquote(ending), rest::binary>>, {line, _unit}, {current_line, prev_lines}) do
      edits = {[], [current_line | prev_lines]}
      advance(rest, {line + 1, starting_character()}, edits)
    end
  end

  defp advance(<<c, rest::binary>>, {line, unit}, edits) when c < 128 do
    advance(rest, {line, unit + 1}, edits)
  end

  defp advance(<<c::utf8, rest::binary>>, {line, unit}, edits) do
    increment = CodeUnit.count(:utf8, <<c::utf8>>)
    advance(rest, {line, unit + increment}, edits)
  end

  defp edit(document, text, start_line, start_unit, end_line, end_unit)
       when is_binary(text) do
    Edit.new(
      text,
      Range.new(
        Position.new(document, start_line, start_unit),
        Position.new(document, end_line, end_unit)
      )
    )
  end

  defp starting_line, do: 1
  defp starting_character, do: 1
end
