defmodule Forge.AstTest do
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Position
  alias Sourceror.Zipper

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.PositionSupport
  import Forge.Test.RangeSupport

  use ExUnit.Case, async: true

  describe "cursor_path/2" do
    defp cursor_path(text) do
      {position, document} = pop_cursor(text, as: :document)
      Ast.cursor_path(document, position)
    end

    test "contains the parent AST" do
      text = ~q[
        defmodule Foo do
          def bar do
            |
          end
        end
      ]

      path = cursor_path(text)

      assert Enum.any?(path, &match?({:def, _, _}, &1))
      assert Enum.any?(path, &match?({:defmodule, _, _}, &1))
    end

    test "returns cursor ast when is not in a container" do
      text = ~q[
        |
        defmodule Foo do
        end
      ]

      path = cursor_path(text)
      assert path == [{:__cursor__, [closing: [line: 1, column: 12], line: 1, column: 1], []}]
    end

    test "returns [] when can't parse the AST" do
      text = ~q[
        foo(bar do baz, [bat|
      ]

      path = cursor_path(text)
      assert path == []
    end
  end

  describe "path_at/2" do
    defp path_at(text) do
      {position, document} = pop_cursor(text, as: :document)
      Ast.path_at(document, position)
    end

    defp end_location({_, metadata, _}), do: end_location(metadata)

    defp end_location(metadata) when is_list(metadata) do
      case metadata do
        [line: line, column: column] ->
          {line, column}

        metadata ->
          [end_line: line, end_column: column] = Keyword.take(metadata, [:end_line, :end_column])

          {line, column}
      end
    end

    test "returns an error if the cursor cannot be found in any node" do
      code = ~q[
        |
        defmodule Foo do
        end
      ]

      assert {:error, :not_found} = path_at(code)
    end

    test "returns an error if the AST cannot be parsed" do
      code = ~q[
        defmodule |Foo do
      ]

      assert {:error, {metadata, "missing terminator: end" <> _, ""}} = path_at(code)
      assert end_location(metadata) == {2, 1}
    end

    test "returns a path to the innermost leaf at position" do
      code = ~q[
        defmodule Foo do
          def bar do
            %{foo: |:ok}
          end
        end
      ]

      assert {:ok, [{:__block__, _, [:ok]} | _]} = path_at(code)
    end

    test "returns a path to the innermost branch at position" do
      code = ~q[
        defmodule Foo do
          |
        end
      ]

      assert {:ok, [{:defmodule, _, _}]} = path_at(code)
    end

    test "returns a path containing all ancestors" do
      code = ~q[
        defmodule Foo do
          def |bar do
            :ok
          end
        end
      ]

      assert {:ok,
              [
                {:bar, _, nil},
                {:def, _, _},
                {_, _},
                [{_, _}],
                {:defmodule, _, _}
              ]} = path_at(code)
    end

    test "returns a path to an outer struct node" do
      code = ~q[
        defmodule Foo do
          |%MyStruct{}
        end
      ]

      assert {:ok, [{:%, _, _} | _]} = path_at(code)
    end
  end

  describe "traverse_line" do
    setup do
      text = ~q[
        line = 1
        line = 2
        line = 3
        line = 4
        ""
      ]t

      document = Document.new("file:///file.ex", text, 1)

      {:ok, document: document}
    end

    defp underscore_variable(%Zipper{node: {var_name, meta, nil}} = zipper) do
      Zipper.replace(zipper, {:"_#{var_name}", meta, nil})
    end

    defp underscore_variable(zipper), do: zipper

    defp underscore_variable(%Zipper{node: {_var_name, _meta, nil}} = zipper, acc) do
      zipper = underscore_variable(zipper)
      {zipper, acc + 1}
    end

    defp underscore_variable(zipper, acc), do: {zipper, acc}

    defp modify({:ok, zipper}) do
      %Zipper{node: ast} = Zipper.top(zipper)
      Sourceror.to_string(ast)
    end

    defp modify({:ok, zipper, acc}) do
      {modify({:ok, zipper}), acc}
    end

    test "/3 should only affect the specified line", %{document: doc} do
      converted =
        doc
        |> Ast.traverse_line(2, &underscore_variable/1)
        |> modify()

      assert converted =~ "_line = 2"
      assert converted =~ "line = 1"
      assert converted =~ "line = 3"
      assert converted =~ "line = 4"
    end

    test "/4 should only affect the specified line, and keeps an accumulator", %{document: doc} do
      {converted, acc} =
        doc
        |> Ast.traverse_line(2, 0, &underscore_variable/2)
        |> modify()

      assert acc == 1
      assert converted =~ "_line = 2"
      refute converted =~ "_line = 1"
      refute converted =~ "_line = 3"
    end
  end

  describe "contains_position?/2 single line node" do
    setup do
      {range, code} = pop_range(~q|
        [
          «single_line_call(1, 2, 3)»
        ]
      |)

      [single_line_ast] = ast(code)

      {:ok, [ast: single_line_ast, range: range]}
    end

    test "at the bounds", %{ast: ast, range: range} do
      assert Ast.contains_position?(ast, range.start)
      assert Ast.contains_position?(ast, range.end)
    end

    test "within the node", %{ast: ast, range: range} do
      position = %{range.start | character: range.start.character + 1}
      assert Ast.contains_position?(ast, position)
    end

    test "outside the bounds", %{ast: ast, range: range} do
      %Position{line: start_line, character: start_col} = range.start
      %Position{line: end_line, character: end_col} = range.end

      refute Ast.contains_position?(ast, position(start_line, start_col - 1))
      refute Ast.contains_position?(ast, position(start_line - 1, start_col))
      refute Ast.contains_position?(ast, position(end_line, end_col + 1))
      refute Ast.contains_position?(ast, position(end_line + 1, end_col))
    end
  end

  describe "contains_position?/2 multi line node" do
    setup do
      {range, code} = pop_range(~q|
        [
          «multi_line_call(
            1, 2, 3
          )»
        ]
      |)

      [three_line_ast] = ast(code)

      {:ok, [ast: three_line_ast, range: range]}
    end

    test "at the bounds", %{ast: ast, range: range} do
      assert Ast.contains_position?(ast, range.start)
      assert Ast.contains_position?(ast, range.end)
    end

    test "on the first line", %{ast: ast, range: range} do
      %Position{line: start_line, character: start_col} = range.start

      assert Ast.contains_position?(ast, position(start_line, start_col + 1))
      refute Ast.contains_position?(ast, position(start_line, start_col - 1))
    end

    test "on the last line", %{ast: ast, range: range} do
      %Position{line: end_line, character: end_col} = range.end

      assert Ast.contains_position?(ast, position(end_line, end_col - 1))
      refute Ast.contains_position?(ast, position(end_line, end_col + 1))
    end

    test "within the lines", %{ast: ast, range: range} do
      %Position{line: start_line} = range.start

      assert Ast.contains_position?(ast, position(start_line + 1, 1))
      assert Ast.contains_position?(ast, position(start_line + 1, 1_000))
    end

    test "outside the lines", %{ast: ast, range: range} do
      %Position{line: start_line, character: start_col} = range.start
      %Position{line: end_line, character: end_col} = range.end

      refute Ast.contains_position?(ast, position(start_line - 1, start_col))
      refute Ast.contains_position?(ast, position(end_line + 1, end_col))
    end
  end

  describe "analyze/1" do
    test "creates an analysis from a document with valid ast" do
      code = ~q[
        defmodule Valid do
        end
      ]

      assert %Analysis{} = analysis = analyze(code)
      assert {:defmodule, _, _} = analysis.ast
    end

    test "creates an analysis from a document with invalid ast" do
      code = ~q[
        defmodule Invalid do
      ]

      assert %Analysis{} = analysis = analyze(code)
      refute analysis.ast
      assert {:error, _} = analysis.parse_error
    end

    test "creates an analysis from a document with incomplete `as` section" do
      code = ~q[
        defmodule Invalid do
          alias Foo, a
        end
      ]

      assert %Analysis{} = analysis = analyze(code)
      assert {:defmodule, _, _} = analysis.ast
    end

    test "handles incomplete imports" do
      code = ~q[
        defmodule Invalid do
          import Other, only: :m
        end
      ]
      assert %Analysis{} = analyze(code)
    end
  end

  defp ast(s) do
    case Ast.from(s) do
      {:ok, {:__block__, _, [node]}, _comments} -> node
      {:ok, node, _comments} -> node
    end
  end

  defp analyze(code) when is_binary(code) do
    document = Document.new("file:///file.ex", code, 0)
    Ast.analyze(document)
  end
end
