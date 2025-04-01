defmodule Lexical.RemoteControl.CodeAction.Handlers.RefactorexTest do
  use Lexical.Test.CodeMod.Case

  alias Lexical.Document
  alias Lexical.RemoteControl.CodeAction.Handlers.Refactorex

  import Lexical.Test.RangeSupport
  import Lexical.Test.CodeSigil

  def apply_code_mod(original_text, _ast, options) do
    document = Document.new("file:///file.ex", original_text, 0)

    changes =
      document
      |> Refactorex.actions(options[:range], [])
      |> Enum.find(&(&1.title == options[:title]))
      |> then(& &1.changes.edits)

    {:ok, changes}
  end

  defp assert_refactored(title, original, refactored) do
    {range, original} = pop_range(original)
    assert {:ok, ^refactored} = modify(original, range: range, title: title)
  end

  test "Refactorex works with the cursor position" do
    assert_refactored(
      "Underscore variables not used",
      ~q[
        def my_«»func(unused) do
        end
      ],
      ~q[
        def my_func(_unused) do
        end]
    )
  end

  test "Refactorex works with a selection" do
    assert_refactored(
      "Extract variable",
      ~q[
        def my_func() do
          «42»
        end
      ],
      ~q[
        def my_func() do
          extracted_variable = 42
          extracted_variable
        end]
    )
  end

  test "Refactorex works with a multiline position" do
    assert_refactored(
      "Extract anonymous function",
      ~q[
      defmodule Foo do
        def my_func() do
          Enum.map(1..2, «fn i ->
            i + 20
          end»)
        end
      end],
      ~q[
      defmodule Foo do
        def my_func() do
          Enum.map(1..2, &extracted_function(&1))
        end

        defp extracted_function(i) do
          i + 20
        end
      end]
    )
  end
end
