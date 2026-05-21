defmodule Forge.Document.LineParser do
  @moduledoc """
  A parser that parses a binary into `Forge.Document.Line` records.

  The approach taken by the parser is to first go through the binary to find out where
  the lines break, what their endings are and if the line is ascii. As we go through the
  binary, we store this information, and when we're done, go back and split up the binary
  using `binary_slice`. This performs 3x faster than iterating through the binary and collecting
  IOlists that represent each line.

  I determines if a line is ascii (and what it really means is utf8 ascii) by checking to see if
  each byte is greater than 0 and less than 128. UTF-16 files won't be marked as ascii, which
  allows us to skip a lot of byte conversions later in the process.
  """
  import Forge.Document.Line

  # it's important that "\r\n" comes before \r here, otherwise the generated pattern
  # matches won't match.
  @endings ["\r\n", "\r", "\n"]
  @max_ascii_character 127

  @doc """
  Parses the text into lines

  Parses the given text into lines, and uses `starting_index` as the first line's line number.
  Passing 0 as starting_index yields a zero-based collection, while passing 1 yields a 1-based
  collection.
  """
  def parse(text, starting_index) do
    text
    |> traverse(starting_index)
    |> Enum.reduce([], fn index, acc -> [extract_line(text, index) | acc] end)
  end

  defp extract_line(text, {line_number, start, stop, is_ascii?, ending}) do
    line_text = binary_part(text, start, stop)
    line(line_number: line_number, text: line_text, ascii?: is_ascii?, ending: ending)
  end

  defp traverse(text, starting_index) do
    traverse(text, 0, starting_index, 0, true, [])
  end

  for ending <- @endings,
      ending_length = byte_size(ending) do
    defp traverse(
           <<unquote(ending)>>,
           current_index,
           line_number,
           line_start_index,
           is_ascii?,
           acc
         ) do
      line_length = current_index - line_start_index
      line_index = {line_number, line_start_index, line_length, is_ascii?, unquote(ending)}
      [line_index | acc]
    end

    defp traverse(
           <<unquote(ending), rest::binary>>,
           current_index,
           line_number,
           line_start_index,
           is_ascii?,
           acc
         ) do
      line_length = current_index - line_start_index

      acc = [{line_number, line_start_index, line_length, is_ascii?, unquote(ending)} | acc]
      next_index = current_index + unquote(ending_length)
      traverse(rest, next_index, line_number + 1, next_index, _is_ascii? = true, acc)
    end
  end

  defp traverse(
         <<c, rest::binary>>,
         current_index,
         line_number,
         line_start_index,
         is_ascii?,
         acc
       ) do
    # Note, this heuristic assumes the NUL character won't occur in elixir source files.
    # if this isn't true, then we need a better heuristic for detecting utf16 text.
    is_still_ascii? = is_ascii? and c <= @max_ascii_character and c > 0

    traverse(
      rest,
      current_index + 1,
      line_number,
      line_start_index,
      is_still_ascii?,
      acc
    )
  end

  defp traverse(<<>>, same_index, _line_number, same_index, _is_ascii, acc) do
    # this is a line at the end of the document with no content
    # I'm choosing not to represent it as a line to simplify things
    # and to make the line count what we expect
    acc
  end

  defp traverse(<<>>, current_index, line_number, line_start_index, is_ascii?, acc) do
    # file doesn't end with a newline
    line_length = current_index - line_start_index
    [{line_number, line_start_index, line_length, is_ascii?, ""} | acc]
  end
end
