defmodule Engine.Build.Error.Location do
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Plugin.V1.Diagnostic.Result

  require Logger

  def stack_to_position([{_, target, _, _} | rest])
      when target not in [:__FILE__, :__MODULE__] do
    stack_to_position(rest)
  end

  def stack_to_position([{_, target, _, context} | _rest])
      when target in [:__FILE__, :__MODULE__] do
    context_to_position(context)
  end

  def stack_to_position([]) do
    nil
  end

  def context_to_position(context) do
    case {context[:line], context[:column]} do
      {nil, nil} ->
        Logger.error("Invalid context: #{inspect(context)}")
        nil

      {line, nil} ->
        line

      {line, column} ->
        position(line, column)
    end
  end

  def position(line) do
    line
  end

  def position(line, column) do
    {line, column}
  end

  def fetch_range(%Document{} = document, context) do
    case {context[:end_line], context[:end_column]} do
      {nil, _} ->
        :error

      {end_line, end_column} ->
        {line, column} = {context[:line], context[:column]}
        {:ok, range(document, line, column, end_line, end_column)}
    end
  end

  def range(%Document{} = document, {line, column}, {end_line, end_column}) do
    range(document, line, column, end_line, end_column)
  end

  def range(%Document{} = document, line, column, end_line, end_column) do
    start_position = Position.new(document, line, column)
    end_position = Position.new(document, end_line, end_column)
    Range.new(start_position, end_position)
  end

  def uniq(diagnostics) do
    exacts = Enum.filter(diagnostics, fn diagnostic -> match?(%Range{}, diagnostic.position) end)

    extract_line = fn
      %Result{position: {line, _column}} -> line
      %Result{position: line} -> line
    end

    # Note: Sometimes error and warning appear on one line at the same time
    # So we need to uniq by line and severity,
    # and :error is always more important than :warning
    extract_line_and_severity = &{extract_line.(&1), &1.severity}

    filtered =
      diagnostics
      |> Enum.filter(fn diagnostic -> not match?(%Range{}, diagnostic.position) end)
      |> Enum.sort_by(extract_line_and_severity)
      |> Enum.uniq_by(extract_line)
      |> reject_zeroth_line()

    exacts ++ filtered
  end

  defp reject_zeroth_line(diagnostics) do
    # Since 1.15, Elixir has some nonsensical error on line 0,
    # e.g.: Can't compile this file
    # We can simply ignore it, as there is a more accurate one
    Enum.reject(diagnostics, fn diagnostic ->
      diagnostic.position == 0
    end)
  end
end
