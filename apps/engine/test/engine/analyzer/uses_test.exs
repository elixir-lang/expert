defmodule Engine.Analyzer.UsesTest do
  use ExUnit.Case

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport

  alias Engine.Analyzer
  alias Forge.Ast

  def uses_at_cursor(text) do
    {position, document} = pop_cursor(text, as: :document)

    document
    |> Ast.analyze()
    |> Analyzer.uses_at(position)
  end

  describe "uses at the top level" do
    test "are not present before the use statement" do
      uses = uses_at_cursor("|use OtherModule")

      assert Enum.empty?(uses)
    end

    test "are present after the use statement" do
      uses = uses_at_cursor("use OtherModule |")

      assert uses == [OtherModule]
    end

    test "handles aliased modules" do
      uses =
        ~q[
        alias Other.MyModule
        use MyModule
        |
        ]
        |> uses_at_cursor()

      assert uses == [Other.MyModule]
    end

    test "handles options" do
      uses =
        ~q[
         use Other.Module, key: :value, other_key: :other_value
        |
        ]
        |> uses_at_cursor()

      assert uses == [Other.Module]
    end

    test "handles multiple uses" do
      uses =
        ~q[
        use FirstModule
        use SecondModule
        ]
        |> uses_at_cursor()

      assert uses == [FirstModule, SecondModule]
    end
  end

  describe "in modules" do
    test "begin after the use statement" do
      uses =
        ~q[
        defmodule Outer do
           use Used|
        end
        ]
        |> uses_at_cursor()

      assert uses == [Used]
    end

    test "ends after the module" do
      uses =
        ~q[
        defmodule Outer do
           use Used
        end|
        ]
        |> uses_at_cursor()

      assert uses == []
    end

    test "are available in their module's functions" do
      uses =
        ~q[
        defmodule Outer do
          use Used

          def my_function(a, b) do
          |
          end
        end
        ]
        |> uses_at_cursor()

      assert uses == [Used]
    end

    test "are not available in submodules" do
      uses =
        ~q[
        defmodule Outer do
          use Used
          defmodule Inner do
           |
          end
        end
        ]
        |> uses_at_cursor()

      assert uses == []
    end
  end
end
