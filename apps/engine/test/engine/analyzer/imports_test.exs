defmodule Parent.Child.ImportedModule do
  def _underscore do
  end

  def function do
  end

  def function(a) do
    a + 1
  end

  def function(a, b) do
    a + b
  end

  defmacro macro(a) do
    quote do
      unquote(a) + 1
    end
  end
end

defmodule Override do
  def function do
  end
end

defmodule WithStruct do
  defstruct [:field]
end

defmodule WithSigils do
  def sigil_m(_) do
  end

  def sigil_n(_, _) do
  end
end

defmodule Engine.Ast.Analysis.ImportsTest do
  alias Engine.Analyzer
  alias Forge.Ast
  alias Parent.Child.ImportedModule
  import Forge.Test.CursorSupport
  import Forge.Test.CodeSigil

  use ExUnit.Case

  def imports_at_cursor(text) do
    {position, document} = pop_cursor(text, as: :document)

    document
    |> Ast.analyze()
    |> Analyzer.imports_at(position)
  end

  def assert_imported(imports, module) do
    functions = module.__info__(:functions)
    macros = module.__info__(:macros)

    for {function, arity} <- functions ++ macros,
        function_name = Atom.to_string(function),
        not String.starts_with?(function_name, "_") do
      assert_imported(imports, module, function, arity)
    end
  end

  def assert_imported(imports, module, function, arity) do
    module_imports = Enum.filter(imports, &match?({^module, _, _}, &1))

    assert {module, function, arity} in module_imports
  end

  def refute_imported(imports, module) do
    functions = module.__info__(:functions)
    macros = module.__info__(:macros)

    for {function, arity} <- functions ++ macros do
      refute_imported(imports, module, function, arity)
    end
  end

  def refute_imported(imports, module, function, arity) do
    module_imports = Enum.filter(imports, &match?({^module, _, _}, &1))

    refute {module, function, arity} in module_imports
  end

  describe "top level imports" do
    test "a top-level global import" do
      imports =
        ~q[
          import Parent.Child.ImportedModule
          |
        ]
        |> imports_at_cursor()

      assert_imported(imports, ImportedModule)
    end

    test "single underscore functions aren't imported by default" do
      imports =
        ~q[
          import Parent.Child.ImportedModule
        ]
        |> imports_at_cursor()

      refute_imported(imports, ImportedModule, :_underscore, 0)
    end

    test "double underscore functions aren't selected by default" do
      imports =
        ~q[
          import WithStruct
          |
        ]
        |> imports_at_cursor()

      refute_imported(imports, WithStruct, :__struct__, 0)
      refute_imported(imports, WithStruct, :__struct__, 1)
    end

    test "an import of an aliased module" do
      imports =
        ~q[
        alias Parent.Child.ImportedModule
        import ImportedModule|
        ]
        |> imports_at_cursor()

      assert_imported(imports, ImportedModule)
    end

    test "an import of a module aliased to a different name using as" do
      imports =
        ~q[
          alias Parent.Child.ImportedModule, as: OtherModule
          import OtherModule|
        ]
        |> imports_at_cursor()

      assert_imported(imports, ImportedModule)
    end

    test "an import outside of a module" do
      imports =
        ~q[
          import Parent.Child.ImportedModule
          defmodule Parent do
          |
          end
        ]
        |> imports_at_cursor()

      assert_imported(imports, ImportedModule)
    end

    test "an import inside the body of a module" do
      imports =
        ~q[
          defmodule Basic do
            import Parent.Child.ImportedModule
            |
          end
          ]
        |> imports_at_cursor()

      assert_imported(imports, ImportedModule)
    end

    test "import with a leading __MODULE__" do
      imports =
        ~q[
          defmodule Parent do

            import __MODULE__.Child.ImportedModule
            |
          end
        ]
        |> imports_at_cursor()

      assert_imported(imports, ImportedModule)
    end

    test "can be overridden" do
      imports =
        ~q[
          import Parent.Child.ImportedModule
          import Override
          |
        ]
        |> imports_at_cursor()

      assert_imported(imports, Override)
      assert_imported(imports, ImportedModule, :function, 1)
      assert_imported(imports, ImportedModule, :function, 2)
      assert_imported(imports, ImportedModule, :macro, 1)
    end

    test "can be accessed before being overridden" do
      imports =
        ~q[
          import Parent.Child.ImportedModule
          |
          import Override
        ]
        |> imports_at_cursor()

      assert_imported(imports, ImportedModule)
    end
  end

  describe "nested modules" do
    test "children get their parent's imports" do
      imports =
        ~q[
          defmodule GrandParent do
            import Enum
            defmodule Child do
              |
            end
          end
        ]
        |> imports_at_cursor()

      assert_imported(imports, Enum)
    end

    test "with a child that has an explicit parent" do
      imports =
        ~q[
          defmodule Parent do
            import Enum
            defmodule __MODULE__.Child do
              |
            end
          end
        ]
        |> imports_at_cursor()

      assert_imported(imports, Enum)
    end
  end

  describe "selecting functions" do
    test "it is possible to select all functions" do
      imports =
        ~q[
          import Parent.Child.ImportedModule, only: :functions
          |
        ]
        |> imports_at_cursor()

      refute_imported(imports, ImportedModule, :macro, 1)
      assert_imported(imports, ImportedModule, :function, 0)
      assert_imported(imports, ImportedModule, :function, 1)
      assert_imported(imports, ImportedModule, :function, 2)
    end

    test "it is possible to select all macros" do
      imports =
        ~q[
          import Parent.Child.ImportedModule, only: :macros
          |
        ]
        |> imports_at_cursor()

      assert_imported(imports, ImportedModule, :macro, 1)

      refute_imported(imports, ImportedModule, :function, 0)
      refute_imported(imports, ImportedModule, :function, 1)
      refute_imported(imports, ImportedModule, :function, 2)
    end

    test "it is possible to select all sigils" do
      imports =
        ~q[
          import WithSigils, only: :sigils
          |
      ]
        |> imports_at_cursor()

      assert_imported(imports, WithSigils, :sigil_m, 1)
      assert_imported(imports, WithSigils, :sigil_n, 2)
    end

    test "it is possible to limit imports by name and arity with only" do
      imports =
        ~q{
          import Parent.Child.ImportedModule, only: [function: 0, function: 1]
          |
        }
        |> imports_at_cursor()

      assert_imported(imports, ImportedModule, :function, 0)
      assert_imported(imports, ImportedModule, :function, 1)

      refute_imported(imports, ImportedModule, :function, 2)
      refute_imported(imports, ImportedModule, :macro, 1)
    end

    test "it is possible to limit imports by name and arity with except" do
      imports =
        ~q{
          import Parent.Child.ImportedModule, except: [function: 0]
          |
        }
        |> imports_at_cursor()

      refute_imported(imports, ImportedModule, :function, 0)

      assert_imported(imports, ImportedModule, :function, 1)
      assert_imported(imports, ImportedModule, :function, 2)
      assert_imported(imports, ImportedModule, :macro, 1)
    end

    test "except only erases previous imports" do
      # taken from https://hexdocs.pm/elixir/1.13.0/Kernel.SpecialForms.html#import/2-selector
      imports =
        ~q{
          import Parent.Child.ImportedModule, only: [function: 0, function: 1, function: 2]
          import Parent.Child.ImportedModule, except: [function: 1]
          |
        }
        |> imports_at_cursor()

      assert_imported(imports, ImportedModule, :function, 0)
      assert_imported(imports, ImportedModule, :function, 2)

      refute_imported(imports, ImportedModule, :function, 1)
      refute_imported(imports, ImportedModule, :macro, 1)
    end

    test "import all by default when a syntax error occurs in the latter part" do
      imports = ~q[
        import Parent.Child.ImportedModule, o
        |
      ] |> imports_at_cursor()

      assert_imported(imports, ImportedModule, :macro, 1)

      assert_imported(imports, ImportedModule, :function, 0)
      assert_imported(imports, ImportedModule, :function, 1)
      assert_imported(imports, ImportedModule, :function, 2)
    end

    test "imports nothing when the only part is incomplete" do
      imports =
        ~q(
        defmodule New do
          import Parent.Child.ImportedModule, only: [wi|]
        end
        )
        |> imports_at_cursor()

      refute_imported(imports, ImportedModule)
    end
  end

  describe "import scopes" do
    test "an import defined in a named function" do
      imports =
        ~q[
          defmodule Parent do
            def fun do
              import Enum
            |
            end
          end
        ]
        |> imports_at_cursor()

      assert_imported(imports, Enum)
    end

    test "an import defined in a named function doesn't leak" do
      imports =
        ~q[
          defmodule Parent do
            def fun do
              import Enum
            end|
          end
        ]
        |> imports_at_cursor()

      refute_imported(imports, Enum)
    end

    test "an import defined in a private named function" do
      imports =
        ~q[
          defmodule Parent do
            defp fun do
              import Enum
              |
            end
          end
        ]
        |> imports_at_cursor()

      assert_imported(imports, Enum)
    end

    test "an import defined in a private named function doesn't leak" do
      imports =
        ~q[
          defmodule Parent do
            defp fun do
              import Enum
            end|
          end
        ]
        |> imports_at_cursor()

      refute_imported(imports, Enum)
    end

    test "an import defined in a DSL" do
      imports =
        ~q[
          defmodule Parent do
             my_dsl do
              import Enum
              |
            end
          end
        ]
        |> imports_at_cursor()

      assert_imported(imports, Enum)
    end

    test "an import defined in a DSL does not leak" do
      imports =
        ~q[
          defmodule Parent do
             my_dsl do
              import Enum
             end
             |
          end
        ]
        |> imports_at_cursor()

      refute_imported(imports, Enum)
    end

    test "an import defined in a anonymous function" do
      imports =
        ~q[
          fn x ->
            import Enum
            |Enum
          end
        ]
        |> imports_at_cursor()

      assert_imported(imports, Enum)
    end

    test "an import defined in a anonymous function doesn't leak" do
      imports =
        ~q[
          fn
            x ->
              import Enum
              Bar.bar(x)
            y ->
             nil|
          end
        ]
        |> imports_at_cursor()

      refute_imported(imports, Enum)
    end

    test "imports to the current module work in a quote block" do
      imports =
        ~q[
        defmodule Parent do
          defmacro __using__(_) do
            quote do
              import unquote(__MODULE__).Child.ImportedModule
              |
            end
          end
        end
        ]
        |> imports_at_cursor()

      assert_imported(imports, Parent.Child.ImportedModule)
    end
  end
end
