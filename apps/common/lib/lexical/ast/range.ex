defmodule Lexical.Ast.Range do
  @moduledoc """
  Utilities for extracting ranges from ast nodes
  """
  alias Lexical.Document
  alias Lexical.Document.Position
  alias Lexical.Document.Range

  @spec fetch(Macro.t(), Document.t()) :: {:ok, Range.t()} | :error
  def fetch(ast, %Document{} = document) do
    case Sourceror.get_range(ast) do
      %{start: start_pos, end: end_pos} ->
        [line: start_line, column: start_column] = start_pos
        [line: end_line, column: end_column] = end_pos

        range =
          Range.new(
            Position.new(document, start_line, start_column),
            Position.new(document, end_line, end_column)
          )

        {:ok, range}

      _ ->
        :error
    end
  end

  @spec fetch!(Macro.t(), Document.t()) :: Range.t()
  def fetch!(ast, %Document{} = document) do
    case fetch(ast, document) do
      {:ok, range} ->
        range

      :error ->
        raise ArgumentError,
          message: "Could not get a range for #{inspect(ast)} in #{document.path}"
    end
  end

  @spec get(Macro.t(), Document.t()) :: Range.t() | nil
  def get(ast, %Document{} = document) do
    case fetch(ast, document) do
      {:ok, range} -> range
      :error -> nil
    end
  end

  @doc """
  Extracts the range subtree from the whole document AST while preserving
  the its positional metadata (differently than Document.fragment/2),
  which facilitates finding these nodes inside the complete AST.

  It's basically the inverse of Range.fetch/2.
  """
  @spec subtree(Document.t(), Range.t()) :: {:ok, Macro.t()} | {:error, term()}
  def subtree(%Document{lines: lines}, %Range{} = range) do
    lines
    |> Stream.map(fn
      {_, line, _, i, _} when i > range.start.line and i < range.end.line ->
        line

      {_, line, _, i, _} when i == range.start.line and i == range.end.line ->
        line
        |> remove_line_start(range)
        |> remove_line_end(range)

      {_, line, _, i, _} when i == range.start.line ->
        remove_line_start(line, range)

      {_, line, _, i, _} when i == range.end.line ->
        remove_line_end(line, range)

      _ ->
        ""
    end)
    |> Enum.join("\n")
    |> Sourceror.parse_string()
  end

  defp remove_line_start(line, %{start: %{character: character}}) do
    {_, line} = String.split_at(line, character - 1)
    String.pad_leading(line, character - 1 + String.length(line), " ")
  end

  defp remove_line_end(line, %{end: %{character: character}}) do
    {line, _} = String.split_at(line, character - 1)
    line
  end
end
