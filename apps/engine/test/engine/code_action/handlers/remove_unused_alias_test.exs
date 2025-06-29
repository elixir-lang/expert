defmodule Engine.CodeAction.Handlers.RemoveUnusedAliasTest do
  alias Engine.CodeAction.Handlers.RemoveUnusedAlias
  alias Forge.Ast
  alias Forge.CodeAction.Diagnostic
  alias Forge.Document
  alias Forge.Document.Range

  import Forge.Test.CursorSupport
  import Forge.Test.CodeSigil

  use Forge.Test.CodeMod.Case, enable_ast_conversion: false

  def apply_code_mod(original_text, _ast, options) do
    Document.Store.open("file:///file.ex", original_text, 1)
    {:ok, document} = Document.Store.fetch("file:///file.ex")

    cursor = Keyword.get(options, :cursor)

    start_pos = update_in(cursor.character, fn _ -> 1 end)
    end_pos = update_in(start_pos.line, &(&1 + 1))

    message =
      case Keyword.get(options, :alias) do
        nil ->
          Keyword.get(options, :message, "warning: unused alias Foo")

        module ->
          "warning: unused alias #{module}"
      end

    range = Document.Range.new(cursor, cursor)
    line_range = Range.new(start_pos, end_pos)

    diagnostic = Diagnostic.new(line_range, message, :elixir)

    edits =
      document
      |> RemoveUnusedAlias.actions(range, [diagnostic])
      |> Enum.flat_map(& &1.changes.edits)

    {:ok, edits}
  end

  def remove_alias(orig_text, opts \\ []) do
    {position, stripped} = pop_cursor(orig_text)

    opts = Keyword.merge(opts, cursor: position)
    modify(stripped, opts)
  end

  setup do
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    :ok
  end

  describe "at the top level" do
    test "removes an alias" do
      assert {:ok, ""} = remove_alias("alias Foo.Bar.Baz|", alias: "Baz")
    end

    test "deletes the line completely" do
      {:ok, doc} =
        ~q[
        alias Foo.Bar.Baz|
        Remote.function_call()
        ]
        |> remove_alias(alias: "Baz")

      assert "Remote.function_call()" == doc
    end

    test "removes an alias in the middle of an alias block" do
      {:ok, removed} =
        ~q[
        alias Foo.Bar.Baz
        alias Quux.Stuff|
        alias Yet.More.Things
        ]
        |> remove_alias(alias: "Stuff")

      assert ~q[
      alias Foo.Bar.Baz
      alias Yet.More.Things
      ] =~ removed
    end

    test "removes an alias at the end of an alias block" do
      {:ok, removed} =
        ~q[
        alias Foo.Bar.Baz
        alias Quux.Stuff
        alias Yet.More.Things|
        ]
        |> remove_alias(alias: "Things")

      assert ~q[
      alias Foo.Bar.Baz
      alias Quux.Stuff
      ] =~ removed
    end

    test "works using as" do
      {:ok, removed} =
        ~q[
        alias Foo.Bar.Baz, as: Quux|
        ]
        |> remove_alias(alias: "Quux")

      assert "" == removed
    end

    test "only deletes the alias on the cursor's line" do
      {:ok, removed} =
        ~q[
        alias Foo.Bar
        alias Something.Else
        alias Foo.Bar|
        ]
        |> remove_alias(alias: "Bar")

      assert ~q[
      alias Foo.Bar
      alias Something.Else
      ] =~ removed
    end

    test "leaves things alone if the message is different" do
      assert {:ok, "alias This.Is.Correct"} ==
               remove_alias("alias This.Is.Correct|", message: "ugly code")
    end
  end

  describe "in a module" do
    test "removes an alias" do
      {:ok, removed} =
        ~q[
        defmodule MyModule do
          alias Foo.Bar.Baz|
        end
        ]
        |> remove_alias(alias: "Baz")

      assert "defmodule MyModule do\nend" =~ removed
    end

    test "removes an alias in the middle of an alias block" do
      {:ok, removed} =
        ~q[
        defmodule MyModule do
          alias Foo.Bar.Baz
          alias Quux.Stuff|
          alias Yet.More.Things
        end
        ]
        |> remove_alias(alias: "Stuff")

      assert ~q[
      defmodule MyModule do
        alias Foo.Bar.Baz
        alias Yet.More.Things
      end
      ] =~ removed
    end

    test "removes an alias at the end of an alias block" do
      {:ok, removed} =
        ~q[
        defmodule MyModule do
          alias Foo.Bar.Baz
          alias Quux.Stuff
          alias Yet.More.Things|
        end
        ]
        |> remove_alias(alias: "Things")

      assert ~q[
      defmodule MyModule do
        alias Foo.Bar.Baz
        alias Quux.Stuff
      end
      ] =~ removed
    end
  end

  describe "in deeply nested modules" do
    test "aliases are removed completely" do
      {:ok, removed} =
        ~q[
         defmodule Grandparent do
           defmodule Parent do
             defmodule Child do
               alias This.Goes.Bye|
             end
           end
         end
        ]
        |> remove_alias(alias: "Bye")

      expected = ~q[
       defmodule Grandparent do
         defmodule Parent do
           defmodule Child do
           end
         end
       end
      ]

      assert expected =~ removed
    end
  end

  describe "multi-line alias block" do
    test "the first alias can be removed" do
      {:ok, removed} =
        ~q[
          alias Grandparent.Parent.|{
            Child1,
            Child2,
            Child3
          }
        ]
        |> remove_alias(alias: "Child1")

      expected = ~q[
        alias Grandparent.Parent.{
          Child2,
          Child3
        }
      ]

      assert expected =~ removed
    end

    test "the second alias can be removed" do
      {:ok, removed} =
        ~q[
          alias Grandparent.Parent.|{
            Child1,
            Child2,
            Child3
          }
        ]
        |> remove_alias(alias: "Child2")

      expected = ~q[
        alias Grandparent.Parent.{
          Child1,
          Child3
        }
      ]

      assert expected =~ removed
    end

    test "the last alias can be removed" do
      {:ok, removed} =
        ~q[
          alias Grandparent.Parent.|{
            Child1,
            Child2,
            Child3
          }
        ]
        |> remove_alias(alias: "Child3")

      expected = ~q[
        alias Grandparent.Parent.{
          Child1,
          Child2
        }
      ]

      assert expected =~ removed
    end

    test "the only alias can be removed" do
      {:ok, removed} =
        ~q[
          alias Grandparent.Parent.|{
            Child1
          }
        ]
        |> remove_alias(alias: "Child1")

      assert "" =~ removed
    end

    test "when there are dotted aliases in the list" do
      {:ok, removed} =
        ~q[
        alias Grandparent.Parent.{
          Child.Stinky,
          Child.Smelly|,
          Other.Reeky
        }
        ]
        |> remove_alias(alias: "Smelly")

      expected = ~q[
        alias Grandparent.Parent.{
          Child.Stinky,
          Other.Reeky
        }
        ]

      assert expected =~ removed
    end
  end

  describe "single-line alias block" do
    test "the first alias can be removed" do
      {:ok, removed} =
        ~q[alias Grandparent.Parent.|{Child1, Child2, Child3}]
        |> remove_alias(alias: "Child1")

      expected = ~q[alias Grandparent.Parent.{Child2, Child3}]

      assert expected =~ removed
    end

    test "the second alias can be removed" do
      {:ok, removed} =
        ~q[alias Grandparent.Parent.|{Child1, Child2, Child3}]
        |> remove_alias(alias: "Child2")

      expected = ~q[
        alias Grandparent.Parent.{Child1, Child3}
      ]

      assert expected =~ removed
    end

    test "the last alias can be removed" do
      {:ok, removed} =
        ~q[
          alias Grandparent.Parent.|{Child1, Child2, Child3}]
        |> remove_alias(alias: "Child3")

      expected = ~q[alias Grandparent.Parent.{Child1, Child2]

      assert expected =~ removed
    end

    test "the only alias can be removed" do
      {:ok, removed} =
        ~q[alias Grandparent.Parent.|{Child1}]
        |> remove_alias(alias: "Child1")

      assert "" =~ removed
    end

    test "when there are dotted aliases in the list" do
      {:ok, removed} =
        "alias Grandparent.Parent.{Child.Stinky, Child.Smelly, Other.Reeky}"
        |> remove_alias(alias: "Smelly")

      assert "alias Grandparent.Parent.{Child.Stinky, Other.Reeky}" =~ removed
    end
  end
end
