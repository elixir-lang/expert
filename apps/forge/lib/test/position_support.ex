defmodule Forge.Test.PositionSupport do
  alias Forge.Document.Edit
  alias Forge.Document.Line
  alias Forge.Document.Lines
  alias Forge.Document.Position
  alias Forge.Document.Range

  import Line

  defmacro __using__(_) do
    quote do
      import unquote(__MODULE__)
    end
  end

  @doc """
  Normalizes any position in items on either side of the operation and runs
  assert on the result.
  """
  defmacro assert_normalized({op, ctx, [left, right]}) do
    normalized = {op, ctx, [do_normalize(left), do_normalize(right)]}

    quote do
      assert unquote(normalized)
    end
  end

  def normalize(%Edit{} = edit) do
    update_in(edit, [:range], &normalize/1)
  end

  def normalize(%Range{} = range) do
    range
    |> update_in([:start], &normalize/1)
    |> update_in([:end], &normalize/1)
  end

  def normalize(%Position{} = position) do
    %Position{
      position
      | context_line: nil,
        valid?: nil,
        document_line_count: nil,
        starting_index: nil
    }
  end

  def do_normalize(thing) do
    quote do
      normalize(unquote(thing))
    end
  end

  @doc """
  Builds a position containing a stub line.
  """
  def position(line, character) do
    stub_line = line(text: "", ending: "\n", line_number: line, ascii?: true)

    lines =
      line
      |> empty_lines()
      |> put_in([Access.key(:lines), Access.elem(line - 1)], stub_line)

    Position.new(lines, line, character)
  end

  defp empty_lines(length) do
    tuple = List.to_tuple(for(x <- 1..length, do: x))
    %Lines{lines: tuple, starting_index: 1}
  end
end
