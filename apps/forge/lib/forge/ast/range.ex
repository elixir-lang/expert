defmodule Forge.Ast.Range do
  @moduledoc """
  Utilities for extracting ranges from ast nodes
  """
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  @parser (case Application.compile_env(:forge, :parser, :spitfire) do
             :spitfire -> Forge.Ast.Parser.Spitfire
             :elixir -> Forge.Ast.Parser.Elixir
           end)

  @spec fetch(Macro.t(), Document.t()) :: {:ok, Range.t()} | :error
  def fetch(ast, %Document{} = document) do
    case extract(ast) do
      %{start: {start_line, start_column}, end: {end_line, end_column}} ->
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

  @spec extract(Macro.t()) ::
          %{start: {pos_integer(), pos_integer()}, end: {pos_integer(), pos_integer()}} | nil
  def extract(ast) do
    ast
    |> @parser.range()
    |> normalize()
  end

  defp normalize(%{start: start_position, end: end_position}) do
    with {start_line, start_column} <- normalize_position(start_position),
         {end_line, end_column} <- normalize_position(end_position) do
      %{start: {start_line, start_column}, end: {end_line, end_column}}
    end
  end

  defp normalize(_), do: nil

  @spec position(keyword()) :: {pos_integer(), pos_integer()} | nil
  def position(metadata) when is_list(metadata), do: normalize_position(metadata)

  def position(_), do: nil

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

  defp normalize_position({line, column}) when is_integer(line) and is_integer(column) do
    {line, column}
  end

  defp normalize_position(metadata) when is_list(metadata) do
    case {Keyword.get(metadata, :line), Keyword.get(metadata, :column)} do
      {line, column} when is_integer(line) and is_integer(column) -> {line, column}
      _ -> nil
    end
  end

  defp normalize_position(_), do: nil
end
