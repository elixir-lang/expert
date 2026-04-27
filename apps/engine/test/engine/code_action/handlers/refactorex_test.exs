defmodule Engine.CodeAction.Handlers.RefactorexTest do
  use Forge.Test.CodeMod.Case
  use Patch

  import Forge.Test.CodeSigil
  import Forge.Test.RangeSupport

  alias Engine.CodeAction.Handlers.Refactorex
  alias Engine.CodeMod.Format
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  def apply_code_mod(original_text, _ast, options) do
    document = Document.new("file:///file.ex", original_text, 0)

    changes =
      document
      |> Refactorex.actions(options[:range], [])
      |> Enum.find(&(&1.title == options[:title]))
      |> then(& &1.changes.edits)

    {:ok, changes}
  end

  defp assert_refactored(title, original, refactored) do
    {range, original} = pop_range(original)
    assert {:ok, ^refactored} = modify(original, range: range, title: title)
  end

  setup do
    project = project()
    Engine.set_project(project)

    {:ok, project: project}
  end

  test "Refactorex works with the cursor position" do
    assert_refactored(
      "Underscore variables not used",
      ~q[
        def my_«»func(unused) do
        end
      ],
      ~q[
        def my_func(_unused) do
        end]
    )
  end

  test "Refactorex works with a selection" do
    assert_refactored(
      "Extract variable",
      ~q[
        def my_func() do
          «42»
        end
      ],
      ~q[
        def my_func() do
          extracted_variable = 42
          extracted_variable
        end]
    )
  end

  test "Refactorex works with a multiline position" do
    assert_refactored(
      "Extract anonymous function",
      ~q[
      defmodule Foo do
        def my_func() do
          Enum.map(1..2, «fn i ->
            i + 20
          end»)
        end
      end],
      ~q[
      defmodule Foo do
        def my_func() do
          Enum.map(1..2, &extracted_function(&1))
        end

        defp extracted_function(i) do
          i + 20
        end
      end]
    )
  end

  test "Refactorex respects formatter line length" do
    patch(Format, :formatter_for_file, fn _project, _path ->
      {nil, [line_length: 120, locals_without_parens: []]}
    end)

    assert_refactored(
      "Remove pipe",
      ~q[
      defmodule Foo do
        def my_func(%{} = map, %{key1: _key1, key2: _key2, key3: _key3, key4: _key4, key5: _key5} = other) do
          «»map |> Map.merge(other)
        end
      end],
      ~q[
      defmodule Foo do
        def my_func(%{} = map, %{key1: _key1, key2: _key2, key3: _key3, key4: _key4, key5: _key5} = other) do
          Map.merge(map, other)
        end
      end]
    )
  end

  test "Refactorex formats when formatter line length is missing" do
    patch(Format, :formatter_for_file, fn _project, _path ->
      {nil, [locals_without_parens: []]}
    end)

    assert_refactored(
      "Remove pipe",
      ~q[
      defmodule Foo do
        def my_func(%{} = map, %{key1: _key1, key2: _key2, key3: _key3, key4: _key4, key5: _key5} = other) do
          «»map |> Map.merge(other)
        end
      end],
      ~q[
      defmodule Foo do
        def my_func(
              %{} = map,
              %{key1: _key1, key2: _key2, key3: _key3, key4: _key4, key5: _key5} = other
            ) do
          Map.merge(map, other)
        end
      end]
    )
  end

  describe "line_or_selection field-level comparison" do
    test "detects cursor position when start and end share same line/character but differ in metadata" do
      code = ~q[
        def my_func(unused) do
        end
      ]

      document = Document.new("file:///file.ex", code, 0)

      start_pos = Position.new(document, 1, 5)

      end_pos = %Position{
        line: start_pos.line,
        character: start_pos.character,
        valid?: start_pos.valid?,
        context_line: start_pos.context_line,
        document_line_count: start_pos.document_line_count,
        starting_index: 0
      }

      assert start_pos.line == end_pos.line
      assert start_pos.character == end_pos.character
      refute start_pos == end_pos

      range = Range.new(start_pos, end_pos)

      actions = Refactorex.actions(document, range, [])

      assert Enum.any?(actions, &(&1.title == "Underscore variables not used")),
             "Expected 'Underscore variables not used' in actions #{inspect(Enum.map(actions, & &1.title))} — " <>
               "line_or_selection fell through to the selection path because start != end despite same line/character"
    end
  end
end
