defmodule Lexical.Ast.RangeTest do
  use ExUnit.Case, async: true

  alias Lexical.Ast.Range
  alias Lexical.Document

  import Lexical.Test.CodeSigil
  import Lexical.Test.RangeSupport

  describe "subtree/2" do
    test "extracts range AST from document but preserves original metadata" do
      {range, code} = pop_range(~q|
      defmodule Foo do
        def read_files(filenames, ext) do
          filenames
          \|> Enum.map(«fn filename ->
            file = File.read!("\#{filename}.\#{ext}")
            String.split(file, "\n")
          end»)
        end
      end
      |)

      document = Document.new("file:///file.ex", code, 0)

      assert {:ok,
              {:fn,
               [
                 trailing_comments: [],
                 leading_comments: [],
                 # original metadata preserved
                 closing: [line: 7, column: 5],
                 line: 4,
                 column: 17
               ], _}} = Range.subtree(document, range)
    end

    test "extracts sibling nodes as a block even if this block wouldn't exist in ast" do
      {range, code} = pop_range(~q|
      defmodule Foo do
        def read_files(filenames, ext) do
          a = 10
          «b = 20
          c = 30»
          d = 40
        end
      end
      |)

      document = Document.new("file:///file.ex", code, 0)

      assert {:ok,
              {:__block__, _,
               [
                 {:=, _, [{:b, _, nil}, _]},
                 {:=, _, [{:c, _, nil}, _]}
               ]}} = Range.subtree(document, range)
    end

    test "returns an error if the range is not equivalent to some node" do
      {range, code} = pop_range(~q|
      defmodule Foo do
        def read_files(filenames) do
          «filenames
        end»
      end
      |)

      document = Document.new("file:///file.ex", code, 0)

      assert {:error, _} = Range.subtree(document, range)
    end
  end
end
