defmodule Engine.CodeAction.Handlers.RequireTest do
  use ExUnit.Case, async: false
  use Patch

  alias Engine.CodeAction.Handlers.Require, as: RequireHandler
  alias Forge.Document
  alias Forge.Document.Range
  alias GenLSP.Structures.Diagnostic

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport

  setup do
    patch(Engine, :get_project, %Forge.Project{})
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    :ok
  end

  defp make_diagnostic(message, range) do
    %Diagnostic{message: message, range: range}
  end

  describe "actions/3" do
    test "adds a require quick fix for Logger macro message" do
      text = ~q[
      defmodule MyModule do
        def log do
          Logger.info|("hi")
        end
      end
      ]

      {cursor, document} = pop_cursor(text, as: :document)
      range = Range.new(cursor, cursor)
      :ok = Document.Store.open(document.uri, Document.to_string(document), document.version)

      diagnostics = [
        make_diagnostic(
          "Logger.info/1 is undefined or private. However, there is a macro with the same name and arity. Be sure to require Logger if you intend to invoke this macro",
          range
        )
      ]

      actions = RequireHandler.actions(document, range, diagnostics)

      assert [action] = actions
      assert action.title == "Add require for Logger"
      assert action.kind == GenLSP.Enumerations.CodeActionKind.quick_fix()
      assert action.changes.edits != []
      assert Enum.any?(action.changes.edits, &String.contains?(&1.text, "require Logger"))
    end

    test "adds require Logger on new line when existing require Kernel is present" do
      text = ~q[
      defmodule Foo do
        require Kernel

        def foo do
          Logger.info|("hello")
        end
      end
      ]

      {cursor, document} = pop_cursor(text, as: :document)
      range = Range.new(cursor, cursor)
      :ok = Document.Store.open(document.uri, Document.to_string(document), document.version)

      diagnostics = [
        make_diagnostic(
          "Logger.info/1 is undefined or private. However, there is a macro with the same name and arity. Be sure to require Logger if you intend to invoke this macro",
          range
        )
      ]

      actions = RequireHandler.actions(document, range, diagnostics)

      assert [action] = actions
      assert action.title == "Add require for Logger"

      # Verify edits contain require Logger
      assert Enum.any?(action.changes.edits, &String.contains?(&1.text, "require Logger"))

      # Apply edits and verify the result has both requires on separate lines
      original_text = Document.to_string(document)

      result_text =
        Forge.Test.CodeMod.Case.apply_edits(original_text, action.changes.edits, trim: false)

      assert result_text =~ ~r/require Kernel\n\s*require Logger/s or
               result_text =~ ~r/require Logger\n\s*require Kernel/s
    end

    test "adds require without extra blank lines between existing requires" do
      text = ~q[
      defmodule Foo do
        require Kernel
        require Logger

        def foo do
          Foo.Test.some_macro|()
        end
      end
      ]

      {cursor, document} = pop_cursor(text, as: :document)
      range = Range.new(cursor, cursor)
      :ok = Document.Store.open(document.uri, Document.to_string(document), document.version)

      diagnostics = [
        make_diagnostic(
          "Foo.Test.some_macro/0 is undefined or private. However, there is a macro with the same name and arity. Be sure to require Foo.Test if you intend to invoke this macro",
          range
        )
      ]

      actions = RequireHandler.actions(document, range, diagnostics)

      assert [action] = actions
      assert action.title == "Add require for Foo.Test"

      # Apply edits
      original_text = Document.to_string(document)

      result_text =
        Forge.Test.CodeMod.Case.apply_edits(original_text, action.changes.edits, trim: false)

      # Verify no extra blank lines between requires (should be consecutive lines)
      assert result_text =~ ~r/require Foo.Test\n\s+require Kernel\n\s+require Logger/

      # Also verify there are no double newlines in the require block
      refute result_text =~ ~r/require \w+\n\n\s+require/
    end

    test "returns empty list when no matching diagnostic" do
      text = ~q[
      defmodule MyModule do
        def log do
          Logger.info|("hi")
        end
      end
      ]

      {cursor, document} = pop_cursor(text, as: :document)
      range = Range.new(cursor, cursor)
      :ok = Document.Store.open(document.uri, Document.to_string(document), document.version)

      diagnostics = [make_diagnostic("something else", range)]

      assert [] == RequireHandler.actions(document, range, diagnostics)
    end
  end
end
