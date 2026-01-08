defmodule Expert.Provider.Handlers.FoldingRange do
  @moduledoc """
  ## Methodology

  ### High level

  We make multiple passes (currently 4) through the source text and create
  folding ranges from each pass.
  Then we merge the ranges from each pass to provide the final ranges.
  Each pass gets a priority to help break ties (the priority is an integer,
  higher integers win).

  ### Indentation pass (priority: 1)

  We use the indentation level -- determined by the column of the first
  non-whitespace character on each line -- to provide baseline ranges.
  All ranges from this pass are `kind?: :region` ranges.

  ### Comment block pass (priority: 2)

  We let "comment blocks", consecutive lines starting with `#`, from regions.
  All ranges from this pass are `kind?: :comment` ranges.

  ### Token-pairs pass (priority: 3)

  We use pairs of tokens, e.g. `do` and `end`, to provide another pass of
  ranges.
  All ranges from this pass are `kind?: :region` ranges.

  ### Special tokens pass (priority: 3)

  We find strings (regular/charlist strings/heredocs) and sigils in a pass as
  they're delimited by a few special tokens.
  Ranges from this pass are either
  - `kind?: :comment` if the token is paired with `@doc` or `@moduledoc`, or
  - `kind?: :region` otherwise.

  ## Notes

  Each pass may return ranges in any order.
  But all ranges are valid, i.e. end_line > start_line.
  """
  alias Expert.Provider.Handlers.FoldingRange
  alias Expert.Provider.Handlers.FoldingRange.Token
  alias Forge.Document
  alias GenLSP.Requests
  alias GenLSP.Structures

  import Forge.Document.Line

  def handle(%Requests.TextDocumentFoldingRange{params: %Structures.FoldingRangeParams{} = params}, _config) do
    document = Document.Container.context_document(params, nil)

    input = document_to_input(document)

    passes_with_priority = [
      {1, FoldingRange.Indentation},
      {2, FoldingRange.CommentBlock},
      {3, FoldingRange.TokenPair},
      {3, FoldingRange.SpecialToken}
    ]

    ranges =
      passes_with_priority
      |> Enum.map(fn {priority, pass} ->
        ranges = ranges_from_pass(pass, input)
        {priority, ranges}
      end)
      |> merge_ranges_with_priorities()

    {:ok, ranges}
  end

  def document_to_input(document) do
    %{
      tokens: tokens(document),
      lines: lines(document)
    }
  end

  defp tokens(document) do
    text = Document.to_string(document)
    Token.format_string(text)
  end

  defp lines(document) do
    for idx <- 1..(Forge.Document.Lines.size(document.lines) - 1) do
      {:ok, line} = Forge.Document.Lines.fetch_line(document.lines, idx)
      {line, indentation(line)}
    end
  end

  defp indentation(line) do
    text = line(line, :text)
    ascii? = line(line, :ascii?)
    full_length = line_length(text, ascii?)
    trimmed = String.trim_leading(text)
    trimmed_length = line_length(trimmed, ascii?)

    if {full_length, trimmed_length} == {0, 0} do
      nil
    else
      full_length - trimmed_length
    end
  end

  defp line_length(text, true) do
    text
    |> byte_size()
    |> div(2)
  end

  defp line_length(text, false) do
    text
    |> characters_to_binary!(:utf8, :utf16)
    |> byte_size()
    |> div(2)
  end

  defp characters_to_binary!(binary, from, to) do
    case :unicode.characters_to_binary(binary, from, to) do
      result when is_binary(result) -> result
    end
  end

  defp ranges_from_pass(pass, input) do
    with {:ok, ranges} <- pass.provide_ranges(input) do
      ranges
    else
      _ -> []
    end
  end

  defp merge_ranges_with_priorities(range_lists_with_priorities) do
    range_lists_with_priorities
    |> Enum.flat_map(fn {priority, ranges} -> Enum.zip(Stream.cycle([priority]), ranges) end)
    |> Enum.group_by(fn {_priority, range} -> range.start_line end)
    |> Enum.map(fn {_start, ranges_with_priority} ->
      {_priority, range} =
        ranges_with_priority
        |> Enum.max_by(fn {priority, range} -> {priority, range.end_line} end)

      range
    end)
    |> Enum.sort_by(& &1.start_line)
  end
end
