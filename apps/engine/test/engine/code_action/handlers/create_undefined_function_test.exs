defmodule Engine.CodeAction.Handlers.CreateUndefinedFunctionTest do
  alias Engine.CodeAction.Handlers.CreateUndefinedFunction
  alias Forge.CodeAction.Diagnostic
  alias Forge.Document

  use Forge.Test.CodeMod.Case

  setup do
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    :ok
  end

  def apply_code_mod(original_text, _ast, options) do
    function_name = Keyword.get(options, :function, "undefined_func")
    arity = Keyword.get(options, :arity, 1)
    line_number = Keyword.get(options, :line, 2)
    visibility = Keyword.get(options, :visibility, :def)

    message = "undefined function #{function_name}/#{arity}"

    :ok = Document.Store.open("file:///file.ex", original_text, 0)
    {:ok, document} = Document.Store.fetch("file:///file.ex")

    range =
      Document.Range.new(
        Document.Position.new(document, line_number, 1),
        Document.Position.new(document, line_number + 1, 1)
      )

    diagnostic = Diagnostic.new(range, message, "Elixir")

    actions = CreateUndefinedFunction.actions(document, range, [diagnostic])

    # Filter to the requested visibility
    visibility_label = if visibility == :def, do: "public", else: "private"

    edits =
      actions
      |> Enum.filter(fn action ->
        String.contains?(action.title, visibility_label)
      end)
      |> Enum.flat_map(& &1.changes.edits)

    :ok = Document.Store.close("file:///file.ex")
    {:ok, edits}
  end

  describe "basic function creation" do
    test "creates a public function with arity 1" do
      {:ok, result} =
        ~q[
        defmodule Foo do
          def hello do
            bye("sorry!")
          end
        end
        ]
        |> modify(function: "bye", arity: 1, line: 3, visibility: :def)

      expected = ~q[
        defmodule Foo do
          def hello do
            bye("sorry!")
          end

          def bye(param1) do
          end
        end
      ]t

      assert result == expected
    end

    test "creates a private function with arity 1" do
      {:ok, result} =
        ~q[
        defmodule Foo do
          def hello do
            bye("sorry!")
          end
        end
        ]
        |> modify(function: "bye", arity: 1, line: 3, visibility: :defp)

      expected = ~q[
        defmodule Foo do
          def hello do
            bye("sorry!")
          end

          defp bye(param1) do
          end
        end
      ]t

      assert result == expected
    end

    test "creates function with arity 0" do
      {:ok, result} =
        ~q[
        defmodule Foo do
          def hello do
            bye()
          end
        end
        ]
        |> modify(function: "bye", arity: 0, line: 3, visibility: :def)

      expected = ~q[
        defmodule Foo do
          def hello do
            bye()
          end

          def bye do
          end
        end
      ]t

      assert result == expected
    end

    test "creates function with multiple parameters" do
      {:ok, result} =
        ~q[
        defmodule Foo do
          def hello do
            calculate(1, 2, 3)
          end
        end
        ]
        |> modify(function: "calculate", arity: 3, line: 3, visibility: :def)

      expected = ~q[
        defmodule Foo do
          def hello do
            calculate(1, 2, 3)
          end

          def calculate(param1, param2, param3) do
          end
        end
      ]t

      assert result == expected
    end
  end

  describe "multi-clause functions" do
    test "inserts after the last clause of the enclosing function" do
      {:ok, result} =
        ~q[
        defmodule Foo do
          def hello(:a) do
            unknown()
          end

          def hello(:b) do
            :b
          end

          def other, do: :other
        end
        ]
        |> modify(function: "unknown", arity: 0, line: 3, visibility: :def)

      expected = ~q[
        defmodule Foo do
          def hello(:a) do
            unknown()
          end

          def hello(:b) do
            :b
          end

          def unknown do
          end

          def other, do: :other
        end
      ]t

      assert result == expected
    end

    test "inserts after clauses matching the arity when function has multiple arities" do
      {:ok, result} =
        ~q[
        defmodule Foo do
          def hello(:a) do
            unknown()
          end

          def hello(:b) do
            :b
          end

          def hello(:a, :extra) do
            :a_extra
          end

          def hello(:b, :extra) do
            :b_extra
          end

          def other, do: :other
        end
        ]
        |> modify(function: "unknown", arity: 0, line: 3, visibility: :def)

      expected = ~q[
        defmodule Foo do
          def hello(:a) do
            unknown()
          end

          def hello(:b) do
            :b
          end

          def unknown do
          end

          def hello(:a, :extra) do
            :a_extra
          end

          def hello(:b, :extra) do
            :b_extra
          end

          def other, do: :other
        end
      ]t

      assert result == expected
    end
  end

  describe "call at module level" do
    test "inserts at end of module when call is in module attribute" do
      {:ok, result} =
        ~q[
        defmodule Foo do
          @attr some_func(:value)

          def existing, do: :ok
        end
        ]
        |> modify(function: "some_func", arity: 1, line: 2, visibility: :def)

      expected = ~q[
        defmodule Foo do
          @attr some_func(:value)

          def existing, do: :ok

          def some_func(param1) do
          end
        end
      ]t

      assert result == expected
    end
  end

  describe "nested modules" do
    test "inserts in the correct nested module" do
      {:ok, result} =
        ~q[
        defmodule Outer do
          def outer_func, do: :outer

          defmodule Inner do
            def hello do
              bye()
            end
          end
        end
        ]
        |> modify(function: "bye", arity: 0, line: 6, visibility: :def)

      expected = ~q[
        defmodule Outer do
          def outer_func, do: :outer

          defmodule Inner do
            def hello do
              bye()
            end

            def bye do
            end
          end
        end
      ]t

      assert result == expected
    end
  end

  describe "non-matching diagnostics" do
    test "returns empty list for non-matching message" do
      original = ~q[
        defmodule Foo do
          def hello do
            x = 1
          end
        end
      ]

      :ok = Document.Store.open("file:///file.ex", original, 0)
      {:ok, document} = Document.Store.fetch("file:///file.ex")

      range =
        Document.Range.new(
          Document.Position.new(document, 3, 1),
          Document.Position.new(document, 4, 1)
        )

      # Use a non-matching diagnostic message
      diagnostic = Diagnostic.new(range, "variable \"x\" is unused", "Elixir")

      actions = CreateUndefinedFunction.actions(document, range, [diagnostic])

      assert actions == []

      :ok = Document.Store.close("file:///file.ex")
    end
  end

  describe "returns both public and private options" do
    test "returns two code actions with correct titles" do
      original = ~q[
        defmodule Foo do
          def hello do
            bye()
          end
        end
      ]

      :ok = Document.Store.open("file:///file.ex", original, 0)
      {:ok, document} = Document.Store.fetch("file:///file.ex")

      range =
        Document.Range.new(
          Document.Position.new(document, 3, 1),
          Document.Position.new(document, 4, 1)
        )

      diagnostic = Diagnostic.new(range, "undefined function bye/0", "Elixir")

      actions = CreateUndefinedFunction.actions(document, range, [diagnostic])

      assert length(actions) == 2

      titles = Enum.map(actions, & &1.title)
      assert "Create public function bye/0" in titles
      assert "Create private function bye/0" in titles

      :ok = Document.Store.close("file:///file.ex")
    end
  end
end
