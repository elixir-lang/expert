defmodule Engine.CodeMod.RequiresTest do
  use ExUnit.Case, async: false
  use Patch

  alias Engine.CodeMod.Requires
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

  def insert_position(orig) do
    {cursor, document} = pop_cursor(orig, as: :document)
    analysis = Ast.analyze(document)
    {position, trailer} = Requires.insert_position(analysis, cursor)
    {:ok, document, position, trailer}
  end

  describe "insert_position" do
    test "is directly after a module's definition if there are no requires present" do
      {:ok, document, position, _trailer} =
        ~q[
        defmodule MyModule do|
        end
        ]
        |> insert_position()

      assert decorate_cursor(document, position) =~ ~q[
      defmodule MyModule do
      |end
      ]
    end

    test "is where existing requires are" do
      {:ok, document, position, _trailer} =
        ~q[
        defmodule MyModule do|
          require Something.That.Exists
        end
        ]
        |> insert_position()

      expected = ~q[
        defmodule MyModule do
          |require Something.That.Exists
        end
      ]

      assert decorate_cursor(document, position) =~ expected
    end
  end

  describe "to_edits" do
    test "writes sorted unique requires and removes old ones" do
      document =
        Document.new(
          "file:///file.ex",
          ~q[
      defmodule MyModule do
        require B.A
        require A.B
      end
      ],
          1
        )

      analysis = Ast.analyze(document)

      {insert_position, trailer} =
        Requires.insert_position(analysis, Position.new(document, 2, 3))

      require_a = %Forge.Ast.Analysis.Require{
        module: [:A, :B],
        as: :B,
        range: Range.new(Position.new(document, 3, 3), Position.new(document, 3, 12))
      }

      require_b = %Forge.Ast.Analysis.Require{
        module: [:B, :A],
        as: :A,
        range: Range.new(Position.new(document, 2, 3), Position.new(document, 2, 12))
      }

      edits = Requires.to_edits([require_a, require_b], insert_position, trailer)

      block_edit = Enum.find(edits, &String.contains?(&1.text, "require"))
      assert block_edit != nil
      assert block_edit.text =~ ~r/require A\.B.*require B\.A/s
    end
  end
end
