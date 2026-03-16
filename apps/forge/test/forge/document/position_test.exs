defmodule Forge.Document.PositionTest do
  use ExUnit.Case, async: true

  import Forge.Document.Line

  alias Forge.Document.Lines
  alias Forge.Document.Position

  describe "compare/2" do
    test "positions on the same line" do
      assert :eq = Position.compare(position(1, 10), position(1, 10))
      assert :gt = Position.compare(position(1, 11), position(1, 10))
      assert :lt = Position.compare(position(1, 9), position(1, 10))
    end

    test "position on earlier line" do
      assert :lt = Position.compare(position(1, 10), position(2, 10))
      assert :lt = Position.compare(position(1, 11), position(2, 10))
      assert :lt = Position.compare(position(1, 9), position(2, 10))
    end

    test "position on later line" do
      assert :gt = Position.compare(position(2, 10), position(1, 10))
      assert :gt = Position.compare(position(2, 11), position(1, 10))
      assert :gt = Position.compare(position(2, 9), position(1, 10))
    end
  end

  defp position(line, character) do
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
