defmodule Expert.Provider.Handlers.FoldingRange.SpecialToken do
  @moduledoc """
  Code folding based on "special" tokens.

  Several tokens, like `"..."`s, define ranges all on their own.
  This module converts these tokens to ranges.
  These ranges can be either `kind: "comment"` or `kind: "region"`.
  """

  alias Expert.Provider.Handlers.FoldingRange.Helpers

  @kinds [
    :bin_heredoc,
    :bin_string,
    :list_heredoc,
    :list_string,
    :sigil
  ]

  @docs [:moduledoc, :typedoc, :doc]

  def provide_ranges(%{tokens: tokens}) do
    ranges =
      tokens
      |> group_tokens()
      |> convert_groups_to_ranges()

    {:ok, ranges}
  end

  def group_tokens(tokens) do
    do_group_tokens(tokens, [])
  end

  defp do_group_tokens([], acc), do: acc

  # Don't create folding ranges for @doc false
  defp do_group_tokens(
         [{:at_op, _, _}, {:identifier, _, doc_identifier}, {false, _, _} | rest],
         acc
       )
       when doc_identifier in @docs do
    do_group_tokens(rest, acc)
  end

  # Start a folding range for `@doc` and `@moduledoc`
  defp do_group_tokens(
         [{:at_op, _, _} = at_op, {:identifier, _, doc_identifier} = token | rest],
         acc
       )
       when doc_identifier in @docs do
    acc = [[token, at_op] | acc]
    do_group_tokens(rest, acc)
  end

  # Amend the folding range
  defp do_group_tokens([{k, _, _} = token | rest], [[{:identifier, _, _} | _] = head | tail])
       when k in @kinds do
    acc = [[token | head] | tail]
    do_group_tokens(rest, acc)
  end

  # Start a new folding range
  defp do_group_tokens([{k, _, _} = token | rest], acc) when k in @kinds do
    acc = [[token] | acc]
    do_group_tokens(rest, acc)
  end

  # Finish the open folding range
  defp do_group_tokens([{:eol, _, _} = token | rest], [[{k, _, _} | _] = head | tail])
       when k in @kinds do
    acc = [[token | head] | tail]
    do_group_tokens(rest, acc)
  end

  defp do_group_tokens([_unmatched_token | rest], acc) do
    do_group_tokens(rest, acc)
  end

  defp convert_groups_to_ranges(groups) do
    groups
    |> Enum.map(fn group ->
      # Each group comes out of group_tokens/1 reversed
      {last, first} = Helpers.first_and_last_of_list(group)
      classify_group(first, last)
    end)
    |> Enum.map(fn {start_line, end_line, kind} ->
      %GenLSP.Structures.FoldingRange{
        start_line: start_line,
        end_line: end_line - 1,
        kind: kind
      }
    end)
    |> Enum.filter(fn range -> range.end_line > range.start_line end)
  end

  defp classify_group({kind, {start_line, _, _}, _}, {_, {end_line, _, _}, _}) do
    kind =
      if kind == :at_op,
        do: GenLSP.Enumerations.FoldingRangeKind.comment(),
        else: GenLSP.Enumerations.FoldingRangeKind.region()

    {start_line, end_line, kind}
  end
end
