defmodule Engine.CodeMod.AliasesTest do
  alias Forge.Ast

  alias Engine.CodeMod.Aliases

  import Forge.Test.CursorSupport
  use Forge.Test.CodeMod.Case
  use Patch

  setup do
    patch(Engine, :get_project, %Forge.Project{})
    :ok
  end

  def insert_position(orig) do
    {cursor, document} = pop_cursor(orig, as: :document)
    analysis = Ast.analyze(document)
    {position, _trailer} = Aliases.insert_position(analysis, cursor)

    {:ok, document, position}
  end

  describe "insert_position" do
    test "is directly after a module's definition if there are no aliases present" do
      {:ok, document, position} =
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

    test "is after the moduledoc if no aliases are present" do
      {:ok, document, position} =
        ~q[
        defmodule MyModule do|
          @moduledoc """
          This is my funny moduledoc
          """
        end
        ]
        |> insert_position()

      assert decorate_cursor(document, position) =~ ~q[
      defmodule MyModule do
        @moduledoc """
        This is my funny moduledoc
        """
      |end
      ]
    end

    test "is before use statements" do
      {:ok, document, position} =
        ~q[
        defmodule MyModule do|
          use Something.That.Exists
        end
        ]
        |> insert_position()

      expected = ~q[
        defmodule MyModule do
          |use Something.That.Exists
        end
      ]
      assert decorate_cursor(document, position) =~ expected
    end

    test "is before require statements" do
      {:ok, document, position} =
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

    test "is before import statements" do
      {:ok, document, position} =
        ~q[
        defmodule MyModule do|
          import Something.That.Exists
        end
        ]
        |> insert_position()

      expected = ~q[
        defmodule MyModule do
          |import Something.That.Exists
        end
      ]
      assert decorate_cursor(document, position) =~ expected
    end

    test "is where existing aliases are" do
      {:ok, document, position} =
        ~q[
        defmodule MyModule do|
          alias Something.That.Exists
        end
        ]
        |> insert_position()

      expected = ~q[
        defmodule MyModule do
          |alias Something.That.Exists
        end
      ]
      assert decorate_cursor(document, position) =~ expected
    end

    test "in nested empty modules" do
      {:ok, document, position} =
        ~q[
        defmodule Outer do
          defmodule Inner do|
          end
        end
        ]
        |> insert_position()

      expected = ~q[
        defmodule Outer do
          defmodule Inner do
          |end
        end
      ]t

      assert decorate_cursor(document, position) =~ expected
    end

    test "in nested modules that both have existing aliases" do
      {:ok, document, position} =
        ~q[
        defmodule Outer do
          alias First.Thing

          defmodule Inner do|
            alias Second.Person
          end
        end
        ]
        |> insert_position()

      expected = ~q[
        defmodule Outer do
          alias First.Thing

          defmodule Inner do
            |alias Second.Person
          end
        end
      ]t

      assert decorate_cursor(document, position) =~ expected
    end

    test "is after moduledocs in nested modules" do
      {:ok, document, position} =
        ~q[
        defmodule Outer do
          alias First.Thing

          defmodule Inner do|
            @moduledoc """
            This is my documentation, it
            spans multiple lines
            """
          end
        end
        ]
        |> insert_position()

      expected = ~q[
        defmodule Outer do
          alias First.Thing

          defmodule Inner do
            @moduledoc """
            This is my documentation, it
            spans multiple lines
            """
          |end
        end
      ]t

      assert decorate_cursor(document, position) =~ expected
    end
  end
end
