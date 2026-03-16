defmodule Forge.Ast.Detection do
  @moduledoc """
  A behavior for context detection

  A context recognizer can recognize the type of code at a current position.
  It is useful for identifying the "part of speech" of a position.

  Note: a given context might be detected by more than one module.
  """

  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document.Position
  alias Forge.Document.Range

  @doc """
  Returns true if the given position is detected by the current module
  """
  @callback detected?(Analysis.t(), Position.t()) :: boolean()

  defmacro __using__(_) do
    quote do
      @behaviour unquote(__MODULE__)

      import unquote(__MODULE__)
    end
  end

  def ancestor_is_def?(%Analysis{} = analysis, %Position{} = position) do
    analysis
    |> Ast.cursor_path(position)
    |> Enum.any?(fn
      {:def, _, _} ->
        true

      {:defp, _, _} ->
        true

      _ ->
        false
    end)
  end

  @type_keys [:type, :typep, :opaque]
  def ancestor_is_type?(%Analysis{} = analysis, %Position{} = position) do
    ancestor_is_attribute?(analysis, position, @type_keys)
  end

  def ancestor_is_spec?(%Analysis{} = analysis, %Position{} = position) do
    ancestor_is_attribute?(analysis, position, :spec)
  end

  def ancestor_is_attribute?(%Analysis{} = analysis, %Position{} = position, attr_name \\ nil) do
    analysis
    |> Ast.cursor_path(position)
    |> Enum.any?(fn
      {:@, metadata, [{found_name, _, _}]} ->
        # single line attribute
        attribute_names_match?(attr_name, found_name) and cursor_in_range?(position, metadata)

      {:__block__, _, [{:@, metadata, [{found_name, _, _}]}, _]} ->
        # multi-line attribute
        attribute_names_match?(attr_name, found_name) and cursor_in_range?(position, metadata)

      _ ->
        false
    end)
  end

  def fetch_range(ast) do
    fetch_range(ast, 0, 0)
  end

  def fetch_range(ast, start_offset, end_offset) do
    case Sourceror.get_range(ast) do
      %{start: [line: start_line, column: start_col], end: [line: end_line, column: end_col]} ->
        range =
          Range.new(
            %Position{line: start_line, character: start_col + start_offset},
            %Position{line: end_line, character: end_col + end_offset}
          )

        {:ok, range}

      nil ->
        :error
    end
  end

  defp cursor_in_range?(position, metadata) do
    expression_end_line = get_in(metadata, [:end_of_expression, :line])
    expression_end_column = get_in(metadata, [:end_of_expression, :column])
    cursor_line = position.line
    cursor_column = position.character

    if cursor_line == expression_end_line do
      expression_end_column > cursor_column
    else
      cursor_line < expression_end_line
    end
  end

  defp attribute_names_match?(expected_names, actual_name)
       when is_list(expected_names),
       do: actual_name in expected_names

  defp attribute_names_match?(nil, _), do: true
  defp attribute_names_match?(same, same), do: true
  defp attribute_names_match?(_, _), do: false
end
