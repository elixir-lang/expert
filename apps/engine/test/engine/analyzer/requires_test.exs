defmodule Engine.Analyzer.RequiresTest do
  use ExUnit.Case

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport

  alias Engine.Analyzer
  alias Forge.Ast

  def requires_at_cursor(text) do
    {position, document} = pop_cursor(text, as: :document)

    document
    |> Ast.analyze()
    |> Analyzer.requires_at(position)
  end

  describe "requires at the top level" do
    test "are not present before the require statement" do
      requires = requires_at_cursor("|require OtherModule")

      assert Enum.empty?(requires)
    end

    test "work for a single require" do
      requires = requires_at_cursor("require OtherModule|")

      assert requires == [OtherModule]
    end

    test "handles aliased modules" do
      requires =
        ~q[
        alias Other.MyModule
        require MyModule|
        ]
        |> requires_at_cursor()

      assert requires == [Other.MyModule]
    end

    test "handles as" do
      requires =
        ~q[
        require Other.Module, as: ReqMod
        |
        ]
        |> requires_at_cursor()

      assert requires == [Other.Module]
    end

    test "work for a multiple require" do
      requires =
        ~q[
        require First
        require Second
        require Third
        |
        ]
        |> requires_at_cursor()

      assert requires == [First, Second, Third]
    end
  end

  describe "in modules" do
    test "begin after the require statement" do
      requires =
        ~q[
        defmodule Outer do
          require Required|
        end
        ]
        |> requires_at_cursor()

      assert requires == [Required]
    end

    test "ends after the module" do
      requires =
        ~q[
        defmodule Outer do
          require Required
        end|
        ]
        |> requires_at_cursor()

      assert requires == []
    end

    test "carries over to nested modules" do
      requires =
        ~q[
        defmodule Outer do
          require Required
          defmodule Inner do
           |
          end
        end
        ]
        |> requires_at_cursor()

      assert requires == [Required]
    end
  end
end
