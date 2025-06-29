defmodule Engine.CodeAction.Handlers.ReplaceWithUnderscoreTest do
  alias Engine.CodeAction.Handlers.ReplaceWithUnderscore
  alias Forge.CodeAction.Diagnostic
  alias Forge.Document

  use Forge.Test.CodeMod.Case

  def apply_code_mod(original_text, _ast, options) do
    variable = Keyword.get(options, :variable, :unused)
    line_number = Keyword.get(options, :line, 1)
    document = Document.new("file:///file.ex", original_text, 0)

    message =
      """
      warning: variable "#{variable}" is unused (if the variable is not meant to be used, prefix it with an underscore)
        /file.ex:#{line_number}
      """
      |> String.trim()

    range =
      Document.Range.new(
        Document.Position.new(document, line_number, 0),
        Document.Position.new(document, line_number + 1, 0)
      )

    diagnostic = Diagnostic.new(range, message, nil)

    changes =
      document
      |> ReplaceWithUnderscore.actions(range, [diagnostic])
      |> Enum.flat_map(& &1.changes.edits)

    {:ok, changes}
  end

  describe "fixes in parameters" do
    test "applied to an unadorned param" do
      {:ok, result} =
        ~q[
          def my_func(unused) do
          end
        ]
        |> modify()

      assert result == "def my_func(_unused) do\nend"
    end

    test "applied to a pattern match in params" do
      {:ok, result} =
        ~q[
          def my_func(%Document{} = unused) do
          end
        ]
        |> modify()

      assert result == "def my_func(%Document{} = _unused) do\nend"
    end

    test "applied to a pattern match preceding a struct in params" do
      {:ok, result} =
        ~q[
          def my_func(unused = %Document{}) do
          end
        ]
        |> modify()

      assert result == "def my_func(_unused = %Document{}) do\nend"
    end

    test "applied prior to a map" do
      {:ok, result} =
        ~q[
          def my_func(unused = %{}) do
          end
        ]
        |> modify()

      assert result == "def my_func(_unused = %{}) do\nend"
    end

    test "applied after a map %{} = unused" do
      {:ok, result} =
        ~q[
          def my_func(%{} = unused) do
          end
        ]
        |> modify()

      assert result == "def my_func(%{} = _unused) do\nend"
    end

    test "applied to a map key %{foo: unused}" do
      {:ok, result} =
        ~q[
          def my_func(%{foo: unused}) do
          end
        ]
        |> modify()

      assert result == "def my_func(%{foo: _unused}) do\nend"
    end

    test "applied to a list element params = [unused, a, b | rest]" do
      {:ok, result} =
        ~q{
          def my_func([unused, a, b | rest]) do
          end
        }
        |> modify()

      assert result == "def my_func([_unused, a, b | rest]) do\nend"
    end

    test "applied to the tail of a list params = [a, b, | unused]" do
      {:ok, result} =
        ~q{
          def my_func([a, b | unused]) do
          end
        }
        |> modify()

      assert result == "def my_func([a, b | _unused]) do\nend"
    end

    test "does not change the name of a function if it is the same as a parameter" do
      {:ok, result} = ~q{
        def unused(unused) do
        end
      } |> modify()
      assert result == "def unused(_unused) do\nend"
    end
  end

  describe "fixes in variables" do
    test "applied to a variable match " do
      {:ok, result} =
        ~q[
          x = 3
        ]
        |> modify(variable: "x")

      assert result == "_x = 3"
    end

    test "applied to a variable match, preserves comments" do
      {:ok, result} =
        ~q[
          unused = bar # TODO: Fix this
        ]
        |> modify()

      assert result == "_unused = bar # TODO: Fix this"
    end

    test "preserves spacing" do
      {:ok, result} =
        "   x = 3"
        |> modify(variable: "x", trim: false)

      assert result == "   _x = 3"
    end

    test "applied to a variable with a pattern matched struct" do
      {:ok, result} =
        ~q[
          unused = %Struct{}
        ]
        |> modify()

      assert result == "_unused = %Struct{}"
    end

    test "applied to a variable with a pattern matched struct preserves trailing comments" do
      {:ok, result} =
        ~q[
          unused = %Struct{} # TODO: fix
        ]
        |> modify()

      assert result == "_unused = %Struct{} # TODO: fix"
    end

    test "applied to struct param matches" do
      {:ok, result} =
        ~q[
          %Struct{field: unused, other_field: used}
        ]
        |> modify()

      assert result == "%Struct{field: _unused, other_field: used}"
    end

    test "applied to a struct module match %module{}" do
      {:ok, result} =
        ~q[
          %unused{field: first, other_field: used}
        ]
        |> modify()

      assert result == "%_unused{field: first, other_field: used}"
    end

    test "applied to a tuple value" do
      {:ok, result} =
        ~q[
          {a, b, unused, c} = whatever
        ]
        |> modify()

      assert result == "{a, b, _unused, c} = whatever"
    end

    test "applied to a list element" do
      {:ok, result} =
        ~q{
          [a, b, unused, c] = whatever
        }
        |> modify()

      assert result == "[a, b, _unused, c] = whatever"
    end

    test "applied to map value" do
      {:ok, result} =
        ~q[
          %{foo: a, bar: unused} = whatever
        ]
        |> modify()

      assert result == "%{foo: a, bar: _unused} = whatever"
    end
  end

  describe "fixes in structures" do
    test "applied to a branch in a case" do
      {:ok, result} =
        ~q[
          case my_thing do
            {:ok, unused} -> :ok
            _ -> :error
          end
        ]t
        |> modify(line: 2)

      expected = ~q[
        case my_thing do
          {:ok, _unused} -> :ok
          _ -> :error
        end
      ]t

      assert result == expected
    end

    test "applied to a match of a comprehension" do
      {:ok, result} =
        ~q[
        for {unused, something_else} <- my_enum, do: something_else
        ]
        |> modify()

      assert result == "for {_unused, something_else} <- my_enum, do: something_else"
    end

    test "applied to a match in a with block" do
      {:ok, result} =
        ~q[
          with {unused, something_else} <- my_enum, do: something_else
        ]
        |> modify()

      assert result == "with {_unused, something_else} <- my_enum, do: something_else"
    end
  end

  test "it preserves the leading indent" do
    {:ok, result} = modify("       {foo, unused, bar}", trim: false)

    assert result == "       {foo, _unused, bar}"
  end
end
