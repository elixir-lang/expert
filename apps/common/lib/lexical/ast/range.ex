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
end
