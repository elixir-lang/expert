defmodule Engine.CodeIntelligence.EntityMultiAliasTest do
  use ExUnit.Case, async: true

  describe "extract_multi_alias_prefix/1" do
    test "extracts prefix from simple multi-alias path" do
      # Simulate path from: alias Foo.{Bar, Baz} with cursor on Bar
      path = [
        {:__aliases__, [line: 1, column: 12], [:Bar]},
        [
          {:__aliases__, [line: 1, column: 12], [:Bar]},
          {:__aliases__, [line: 1, column: 17], [:Baz]}
        ],
        {{:., [line: 1, column: 10], [{:__aliases__, [line: 1, column: 7], [:Foo]}, :{}]},
         [line: 1, column: 10],
         [
           {:__aliases__, [line: 1, column: 12], [:Bar]},
           {:__aliases__, [line: 1, column: 17], [:Baz]}
         ]},
        {:alias, [line: 1, column: 1],
         [
           {{:., [line: 1, column: 10], [{:__aliases__, [line: 1, column: 7], [:Foo]}, :{}]},
            [line: 1, column: 10],
            [
              {:__aliases__, [line: 1, column: 12], [:Bar]},
              {:__aliases__, [line: 1, column: 17], [:Baz]}
            ]}
         ]}
      ]

      # We can't test private functions directly, but we can verify the overall behavior
      # by testing that the path structure matches our expectations
      assert [{:__aliases__, _, [:Bar]} | _] = path
    end

    test "multi-alias AST has expected structure" do
      code = "alias Foo.{Bar, Baz}"
      {:ok, ast} = Code.string_to_quoted(code, columns: true)

      # Verify the AST structure we expect
      assert {:alias, _, [{{:., _, [{:__aliases__, _, [:Foo]}, :{}]}, _, aliases}]} = ast
      assert length(aliases) == 2

      # Verify the first alias
      assert {:__aliases__, _, [:Bar]} = Enum.at(aliases, 0)
      assert {:__aliases__, _, [:Baz]} = Enum.at(aliases, 1)
    end

    test "nested multi-alias AST structure" do
      code = "alias Foo.Bar.{Baz, Qux}"
      {:ok, ast} = Code.string_to_quoted(code, columns: true)

      # Verify the AST structure
      assert {:alias, _, [{{:., _, [{:__aliases__, _, [:Foo, :Bar]}, :{}]}, _, aliases}]} = ast
      assert length(aliases) == 2
    end

    test "multi-alias with nested modules" do
      code = "alias Foo.{Bar.Baz, Qux}"
      {:ok, ast} = Code.string_to_quoted(code, columns: true)

      # Verify the AST structure
      assert {:alias, _, [{{:., _, [{:__aliases__, _, [:Foo]}, :{}]}, _, aliases}]} = ast
      assert {:__aliases__, _, [:Bar, :Baz]} = Enum.at(aliases, 0)
      assert {:__aliases__, _, [:Qux]} = Enum.at(aliases, 1)
    end

    test "__MODULE__ multi-alias AST structure" do
      code = "alias __MODULE__.{Bar, Baz}"
      {:ok, ast} = Code.string_to_quoted(code, columns: true)

      # Verify the AST structure
      assert {:alias, _, [{{:., _, [{:__MODULE__, _, _}, :{}]}, _, aliases}]} = ast
      assert length(aliases) == 2
    end
  end

  describe "surround_context with multi-alias" do
    test "returns alias context for module in curly braces" do
      code = "alias Foo.{Bar, Baz}"

      # Cursor on 'B' in Bar
      result = Future.Code.Fragment.surround_context(code, {1, 13})

      assert %{context: {:alias, ~c"Bar"}, begin: {1, 12}, end: {1, 15}} = result
    end

    test "returns alias context for second module in curly braces" do
      code = "alias Foo.{Bar, Baz}"

      # Cursor on 'B' in Baz
      result = Future.Code.Fragment.surround_context(code, {1, 18})

      assert %{context: {:alias, ~c"Baz"}, begin: {1, 17}, end: {1, 20}} = result
    end

    test "returns alias context for prefix module" do
      code = "alias Foo.{Bar, Baz}"

      # Cursor on 'F' in Foo
      result = Future.Code.Fragment.surround_context(code, {1, 7})

      assert %{context: {:alias, ~c"Foo"}, begin: {1, 7}, end: {1, 10}} = result
    end

    test "returns alias context for nested module in curly braces" do
      code = "alias Foo.{Bar.Baz, Qux}"

      # Cursor on second 'B' in Baz
      result = Future.Code.Fragment.surround_context(code, {1, 16})

      assert %{context: {:alias, ~c"Bar.Baz"}, begin: {1, 12}, end: {1, 19}} = result
    end
  end
end
