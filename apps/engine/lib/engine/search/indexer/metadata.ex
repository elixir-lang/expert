defmodule Engine.Search.Indexer.Metadata do
  @moduledoc """
  Utilities for extracting location information from AST metadata nodes.
  """

  def location({_, metadata, _} = ast) do
    if Keyword.has_key?(metadata, :do) do
      position = position(metadata)
      block_start = position(metadata, :do)
      block_end = position(metadata, :end_of_expression) || position(metadata, :end)
      {:block, position, block_start, block_end}
    else
      maybe_handle_terse_function(ast)
    end
  end

  def location(_unknown) do
    {:expression, nil}
  end

  def position(keyword) when is_list(keyword), do: Forge.Ast.Range.position(keyword)

  def position(_), do: nil

  def position(keyword, key) do
    keyword
    |> Keyword.get(key, [])
    |> position()
  end

  @defines [:def, :defp, :defmacro, :defmacrop, :fn]
  # a terse function is one without a do/end block
  defp maybe_handle_terse_function({define, metadata, [_name_and_args | [[block | _]]]})
       when define in @defines do
    block_location(block, metadata)
  end

  defp maybe_handle_terse_function({:fn, metadata, _} = ast) do
    block_location(ast, metadata)
  end

  defp maybe_handle_terse_function({_, metadata, _}) do
    {:expression, position(metadata)}
  end

  defp block_location(block, metadata) do
    case Forge.Ast.Range.extract(block) do
      %{start: {start_line, start_column}, end: {end_line, end_column}} ->
        position = position(metadata)
        {:block, position, {start_line, start_column}, {end_line, end_column}}

      _ ->
        {:expression, position(metadata)}
    end
  end
end
