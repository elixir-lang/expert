defmodule Expert.Provider.Handlers.FoldingRange.CommentBlock do
  @moduledoc """
  Code folding based on comment blocks

  Note that this implementation can create comment ranges inside heredocs.
  It's a little sloppy, but it shouldn't be very impactful.
  We'd have to merge the token and line representations of the source text to
  mitigate this issue, so we've left it as is for now.
  """
  alias Expert.Provider.Handlers.FoldingRange.Helpers

  import Forge.Document.Line

  def provide_ranges(%{lines: lines}) do
    ranges =
      lines
      |> Enum.map(&extract_cell/1)
      |> group_comments()
      |> Enum.filter(fn group -> length(group) > 1 end)
      |> Enum.map(&convert_comment_group_to_range/1)

    {:ok, ranges}
  end

  def extract_cell({line(line_number: line), indentation}), do: {line, indentation}

  def group_comments(lines) do
    lines
    |> Enum.reduce([[]], fn
      {_, cell, "#"}, [[{_, "#"} | _] = head | tail] ->
        [[{cell, "#"} | head] | tail]

      {_, cell, "#"}, [[] | tail] ->
        [[{cell, "#"}] | tail]

      _, [[{_, "#"} | _] | _] = acc ->
        [[] | acc]

      _, acc ->
        acc
    end)
  end

  defp convert_comment_group_to_range(group) do
    {{{end_line, _}, _}, {{start_line, _}, _}} =
      Helpers.first_and_last_of_list(group)

    %GenLSP.Structures.FoldingRange{
      start_line: start_line,
      # We're not doing end_line - 1 on purpose.
      # It seems weird to show the first _and_ last line of a comment block.
      end_line: end_line,
      kind: GenLSP.Enumerations.FoldingRangeKind.comment()
    }
  end
end
