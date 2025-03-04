defmodule Lexical.RemoteControl.CodeAction.Handlers.RefactorexTest do
  alias Lexical.Document
  alias Lexical.RemoteControl.CodeAction.Diagnostic
  alias Lexical.RemoteControl.CodeAction.Handlers.Refactorex

  use Lexical.Test.CodeMod.Case

  def apply_code_mod(original_text, _ast, options) do
    {{l1, c1}, {l2, c2}} = options[:range]

    document = Document.new("file:///file.ex", original_text, 0)
    range = Document.Range.new(
      Document.Position.new(document, l1, c1),
      Document.Position.new(document, l2, c2)
    )
    diagnostic = Diagnostic.new(range, "", nil)

    changes =
      document
      |> Refactorex.actions(range, [diagnostic])
      |> Enum.find(& &1.title == options[:title])
      |> then(& &1.changes.edits)

    {:ok, changes}
  end

  test "underscore variables not used" do
    {:ok, result} =
      ~q[
        def my_func(unused) do
        end
      ]
      |> modify(range: {{1, 1}, {1, 1}}, title: "Underscore variables not used")

    assert result == ~q[
      def my_func(_unused) do
      end]
  end

  test "extract variable" do
    {:ok, result} =
      ~q[
        def my_func() do
          42
        end
      ]
      |> modify(range: {{2, 3}, {2, 5}}, title: "Extract variable")

    assert result == ~q[
      def my_func() do
        extracted_variable = 42
        extracted_variable
      end]
  end
end
