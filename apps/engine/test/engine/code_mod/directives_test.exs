defmodule Engine.CodeMod.DirectivesTest do
  use ExUnit.Case, async: false
  use Patch

  alias Engine.CodeMod.Directives
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport

  setup do
    patch(Engine, :get_project, %Forge.Project{})
    :ok
  end

  describe "insert_position/3" do
    test "returns global start with trailer when no directives" do
      document = Document.new("file:///file.ex", ~q[IO.puts("hi")], 1)
      cursor = Position.new(document, 1, 1)
      analysis = Ast.analyze(document)

      {position, trailer} = Directives.insert_position(analysis, Range.new(cursor, cursor), [])

      assert position.line == 1
      assert position.character == 1
      assert trailer == "\n"
    end

    test "returns first existing directive position without trailer" do
      {cursor, document} =
        pop_cursor(~q[
      defmodule MyModule do
        alias Foo|
        alias Bar
      end
      ],
          as: :document
        )

      analysis = Ast.analyze(document)
      range = Range.new(cursor, cursor)

      first_alias_range = Range.new(Position.new(document, 2, 3), Position.new(document, 2, 6))
      fake = %{range: first_alias_range}

      {position, trailer} = Directives.insert_position(analysis, range, [fake])

      assert position == first_alias_range.start
      assert trailer == nil
    end
  end

  describe "to_edits/4" do
    defp render(%{text: text}), do: "decl " <> text
    defp sort_key(%{text: text}), do: text
    defp range_of(%{range: range}), do: range

    test "dedupes, sorts, removes old ranges, and inserts block" do
      document =
        Document.new(
          "file:///file.ex",
          ~q[
      defmodule MyModule do
        decl b
        decl a
      end
      ],
          1
        )

      items = [
        %{
          text: "b",
          range: Range.new(Position.new(document, 2, 3), Position.new(document, 2, 8))
        },
        %{
          text: "a",
          range: Range.new(Position.new(document, 3, 3), Position.new(document, 3, 8))
        },
        %{text: "a", range: nil}
      ]

      insert_position = Position.new(document, 2, 3)

      edits =
        Directives.to_edits(items, insert_position, "\n",
          render: &render/1,
          sort_by: &sort_key/1,
          range: &range_of/1
        )

      assert length(edits) >= 2
      [insert_edit | delete_edits] = edits
      assert String.contains?(insert_edit.text, "decl a")
      assert String.contains?(insert_edit.text, "decl b")
      assert Enum.all?(delete_edits, &(&1.text == ""))
    end
  end
end
