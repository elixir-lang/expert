defmodule Lexical.RemoteControl.CodeAction.Handlers.RefactorexTest do
  use Lexical.Test.CodeMod.Case

  alias Lexical.Document
  alias Lexical.RemoteControl.CodeAction.Diagnostic
  alias Lexical.RemoteControl.CodeAction.Handlers.Refactorex

  import Lexical.Test.RangeSupport

  def apply_code_mod(original_text, _ast, options) do
    range = options[:range]

    document = Document.new("file:///file.ex", original_text, 0)
    diagnostic = Diagnostic.new(range, "", nil)

    changes =
      document
      |> Refactorex.actions(range, [diagnostic])
      |> Enum.find(&(&1.title == options[:title]))
      |> then(& &1.changes.edits)

    {:ok, changes}
  end

  test "underscore variables not used" do
    {range, original} = pop_range(~q[
      def my_f«»unc(unused) do
      end
    ])

    refactored = ~q[
    def my_func(_unused) do
    end]

    assert {:ok, ^refactored} =
             modify(original, range: range, title: "Underscore variables not used")
  end

  test "extract variable" do
    {range, original} = pop_range(~q[
      def my_func() do
        «42»
      end
    ])

    refactored = ~q[
      def my_func() do
        extracted_variable = 42
        extracted_variable
      end]

    assert {:ok, ^refactored} = modify(original, range: range, title: "Extract variable")
  end
end
