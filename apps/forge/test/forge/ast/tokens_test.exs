defmodule Forge.Ast.TokensTest do
  alias Forge.Ast.Tokens

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport

  use ExUnit.Case, async: true

  describe "prefix_stream/2" do
    test "works as intended" do
      text = ~q[
        defmodule Foo do
          def bar do
            |
          end
        end
      ]

      {position, document} = pop_cursor(text, as: :document)

      tokens = Tokens.prefix_stream(document, position)

      assert Enum.to_list(tokens) == [
               {:eol, ~c"\n", []},
               {:operator, :do, {2, 11}},
               {:do_identifier, ~c"bar", {2, 7}},
               {:identifier, ~c"def", {2, 3}},
               {:eol, ~c"\n", []},
               {:operator, :do, {1, 15}},
               {:alias, ~c"Foo", {1, 11}},
               {:identifier, ~c"defmodule", {1, 1}}
             ]
    end

    test "returns nothing when cursor is at start" do
      text = ~q[
        |defmodule Foo do
          def bar do
            :bar
          end
        end
      ]

      {position, document} = pop_cursor(text, as: :document)

      tokens = Tokens.prefix_stream(document, position)

      assert Enum.to_list(tokens) == []
    end

    test "works on empty interpolations" do
      text = ~S|"foo#{}bar"|

      {position, document} = pop_cursor(text <> "|", as: :document)

      tokens = Tokens.prefix_stream(document, position)

      assert Enum.to_list(tokens) == [
               {
                 :interpolated_string,
                 [
                   {:literal, "foo", {{1, 1}, {1, 4}}},
                   {:interpolation, [], {{1, 7}, {1, 7}}},
                   {:literal, "bar", {{1, 7}, {1, 10}}}
                 ],
                 {1, 1}
               }
             ]
    end

    test "works on interpolations with newlines" do
      text = ~S[
          ~S"""
          "foo«#{
            2
          }»bar"
          """
          |
          ]

      {position, document} = pop_cursor(text, as: :document)

      tokens = Tokens.prefix_stream(document, position)

      assert Enum.to_list(tokens) == [
               {:eol, ~c"\n", []},
               {:eol, ~c"\n", []},
               {:eol, ~c"\n", []},
               {:eol, ~c"\n", []},
               {
                 :interpolated_string,
                 [
                   {:literal, "foo«", {{1, 1}, {1, 5}}},
                   {:interpolation,
                    [{:eol, {3, 18, 1}}, {:int, {4, 13, 2}, ~c"2"}, {:eol, {4, 14, 1}}],
                    {{3, 18}, {5, 11}}},
                   {:literal, "»bar", {{5, 11}, {5, 15}}}
                 ],
                 {3, 11}
               },
               {:eol, ~c"\n", []},
               {:eol, ~c"\n", []}
             ]
    end
  end
end
