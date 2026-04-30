defmodule Expert.Provider.Handlers.CodeFolding do
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Context
  alias Forge.Ast
  alias Forge.Document
  alias GenLSP.Requests
  alias GenLSP.Structures

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentFoldingRange{params: %Structures.FoldingRangeParams{}},
        %Context{} = context
      ) do
    %Context{document: document} = context
    {:ok, folding_ranges(document)}
  end

  defp folding_ranges(%Document{} = document) do
    case Ast.from(document) do
      {:ok, ast, _comments} ->
        ranges_from(ast)

      {:error, ast, _parse_error, _comments} when is_tuple(ast) ->
        ranges_from(ast)

      _ ->
        []
    end
  end

  defp ranges_from(ast) do
    block_ranges(ast) ++ string_ranges(ast)
  end

  defp block_ranges(ast) do
    {_, ranges} =
      Macro.prewalk(ast, [], fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          {node, collect_block(meta, acc)}

        node, acc ->
          {node, acc}
      end)

    ranges
    |> Enum.map(&to_block_folding_range/1)
    |> Enum.reject(&is_nil/1)
  end

  defp collect_block(meta, acc) do
    do_line = meta_line(meta, :do)
    end_line = meta_line(meta, :end)

    if is_integer(do_line) and is_integer(end_line) do
      [{do_line, end_line} | acc]
    else
      acc
    end
  end

  defp meta_line(meta, key) do
    case Keyword.get(meta, key) do
      keyword when is_list(keyword) -> Keyword.get(keyword, :line)
      _ -> nil
    end
  end

  defp to_block_folding_range({do_line, end_line}) do
    start_line = do_line - 1
    last_line = end_line - 2

    if last_line > start_line do
      %Structures.FoldingRange{start_line: start_line, end_line: last_line}
    end
  end

  defp string_ranges(ast) do
    {_, ranges} =
      Macro.prewalk(ast, [], fn
        {:__block__, meta, [str]} = node, acc when is_binary(str) and is_list(meta) ->
          {node, collect_string(meta, str, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reject(ranges, &is_nil/1)
  end

  defp collect_string(meta, str, acc) do
    start_line = Keyword.get(meta, :line)
    delimiter = Keyword.get(meta, :delimiter)
    newlines = count_newlines(str)

    cond do
      not is_integer(start_line) or newlines < 1 ->
        acc

      delimiter == "\"\"\"" ->
        prepend_string_range(start_line, start_line + newlines + 1, acc)

      delimiter == "\"" ->
        prepend_string_range(start_line, start_line + newlines, acc)

      true ->
        acc
    end
  end

  defp prepend_string_range(open_line, close_line, acc) do
    start_line = open_line - 1
    end_line = close_line - 2

    if end_line > start_line do
      [%Structures.FoldingRange{start_line: start_line, end_line: end_line} | acc]
    else
      acc
    end
  end

  defp count_newlines(str) do
    str |> :binary.matches("\n") |> length()
  end
end
