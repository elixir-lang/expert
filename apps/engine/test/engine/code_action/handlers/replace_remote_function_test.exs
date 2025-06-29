defmodule Engine.CodeAction.Handlers.ReplaceRemoteFunctionTest do
  alias Engine.CodeAction.Handlers.ReplaceRemoteFunction
  alias Forge.CodeAction.Diagnostic
  alias Forge.Document

  use Forge.Test.CodeMod.Case

  setup do
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    :ok
  end

  @default_message """
  Enum.counts/1 is undefined or private. Did you mean:

        * concat/1
        * concat/2
        * count/1
        * count/2
  """

  def apply_code_mod(original_text, _ast, options) do
    line_number = Keyword.get(options, :line, 1)
    message_body = Keyword.get(options, :message, @default_message)
    message_prefix = Keyword.get(options, :message_prefix, "")
    message = message_prefix <> message_body

    suggestion =
      options
      |> Keyword.get(:suggestion, :count)
      |> Atom.to_string()

    :ok = Document.Store.open("file:///file.ex", original_text, 0)
    {:ok, document} = Document.Store.fetch("file:///file.ex")

    range =
      Document.Range.new(
        Document.Position.new(document, line_number, 0),
        Document.Position.new(document, line_number + 1, 0)
      )

    diagnostic = Diagnostic.new(range, message, nil)

    changes =
      document
      |> ReplaceRemoteFunction.actions(range, [diagnostic])
      |> Enum.flat_map(& &1.changes.edits)
      |> Enum.filter(fn
        %Forge.Document.Edit{text: ^suggestion} -> true
        _ -> false
      end)

    {:ok, changes}
  end

  for prefix <- ["", "warning: "] do
    describe "fixes function call with message prefix \"#{prefix}\"" do
      test "applied to a standalone call" do
        {:ok, result} =
          ~q{
          Enum.counts([1, 2, 3])
        }
          |> modify(message_prefix: unquote(prefix))

        assert result == "Enum.count([1, 2, 3])"
      end

      test "applied to a variable match" do
        {:ok, result} =
          ~q{
          x = Enum.counts([1, 2, 3])
        }
          |> modify(message_prefix: unquote(prefix))

        assert result == "x = Enum.count([1, 2, 3])"
      end

      test "applied to a variable match, preserves comments" do
        {:ok, result} =
          ~q{
          x = Enum.counts([1, 2, 3]) # TODO: Fix this
        }
          |> modify(message_prefix: unquote(prefix))

        assert result == "x = Enum.count([1, 2, 3]) # TODO: Fix this"
      end

      test "not changing variable name" do
        {:ok, result} =
          ~q{
          counts = Enum.counts([1, 2, 3])
        }
          |> modify(message_prefix: unquote(prefix))

        assert result == "counts = Enum.count([1, 2, 3])"
      end

      test "applied to a call after a pipe" do
        {:ok, result} =
          ~q{
          [1, 2, 3] |> Enum.counts()
        }
          |> modify(message_prefix: unquote(prefix))

        assert result == "[1, 2, 3] |> Enum.count()"
      end

      test "changing only a function from provided possible modules" do
        {:ok, result} =
          ~q{
          Enumerable.counts([1, 2, 3]) + Enum.counts([3, 2, 1])
        }
          |> modify(message_prefix: unquote(prefix))

        assert result == "Enumerable.counts([1, 2, 3]) + Enum.count([3, 2, 1])"
      end

      test "changing all occurrences of the function in the line" do
        {:ok, result} =
          ~q{
          Enum.counts([1, 2, 3]) + Enum.counts([3, 2, 1])
        }
          |> modify(message_prefix: unquote(prefix))

        assert result == "Enum.count([1, 2, 3]) + Enum.count([3, 2, 1])"
      end

      test "applied in a comprehension" do
        {:ok, result} =
          ~q{
          for x <- Enum.counts([[1], [2], [3]]), do: x
        }
          |> modify(suggestion: :concat)

        assert result == "for x <- Enum.concat([[1], [2], [3]]), do: x"
      end

      test "applied in a with block" do
        {:ok, result} =
          ~q{
          with x <- Enum.counts([1, 2, 3]), do: x
        }
          |> modify(message_prefix: unquote(prefix))

        assert result == "with x <- Enum.count([1, 2, 3]), do: x"
      end

      test "preserving the leading indent" do
        {:ok, result} = modify("     Enum.counts([1, 2, 3])", trim: false)

        assert result == "     Enum.count([1, 2, 3])"
      end

      test "handles erlang functions" do
        message = """
        :ets.inserd/2 is undefined or private. Did you mean:

              * insert/2
              * insert_new/2

        """

        {:ok, result} =
          modify(":ets.inserd(a, b)",
            message: message,
            message_prefix: unquote(prefix),
            suggestion: :insert
          )

        assert result == ":ets.insert(a, b)"
      end
    end

    describe "fixes captured function with message prefix \"#{prefix}\"" do
      test "applied to a standalone function" do
        {:ok, result} =
          ~q[
          &Enum.counts/1
        ]
          |> modify(message_prefix: unquote(prefix))

        assert result == "&Enum.count/1"
      end

      test "applied to a variable match" do
        {:ok, result} =
          ~q[
          x = &Enum.counts/1
        ]
          |> modify(message_prefix: unquote(prefix))

        assert result == "x = &Enum.count/1"
      end

      test "applied to a variable match, preserves comments" do
        {:ok, result} =
          ~q[
          x = &Enum.counts/1 # TODO: Fix this
        ]
          |> modify(message_prefix: unquote(prefix))

        assert result == "x = &Enum.count/1 # TODO: Fix this"
      end

      test "not changing variable name" do
        {:ok, result} =
          ~q{
          counts = &Enum.counts/1
        }
          |> modify(message_prefix: unquote(prefix))

        assert result == "counts = &Enum.count/1"
      end

      test "applied to an argument" do
        {:ok, result} =
          ~q{
          [[1, 2], [3, 4]] |> Enum.map(&Enum.counts/1)
        }
          |> modify(message_prefix: unquote(prefix))

        assert result == "[[1, 2], [3, 4]] |> Enum.map(&Enum.count/1)"
      end

      test "changing only a function from provided possible modules" do
        {:ok, result} =
          ~q{
          [&Enumerable.counts/1, &Enum.counts/1]
        }
          |> modify(message_prefix: unquote(prefix))

        assert result == "[&Enumerable.counts/1, &Enum.count/1]"
      end

      test "changing all occurrences of the function in the line" do
        {:ok, result} =
          ~q{
          [&Enum.counts/1, &Enum.counts/1]
        }
          |> modify(message_prefix: unquote(prefix))

        assert result == "[&Enum.count/1, &Enum.count/1]"
      end

      test "preserving the leading indent" do
        {:ok, result} = modify("     &Enum.counts/1", trim: false)

        assert result == "     &Enum.count/1"
      end

      test "handles erlang functions" do
        message = """
        :ets.inserd/2 is undefined or private. Did you mean:

              * insert/2
              * insert_new/2

        """

        {:ok, result} =
          modify("&:ets.inserd/2",
            message: message,
            message_prefix: unquote(prefix),
            suggestion: :insert
          )

        assert result == "&:ets.insert/2"
      end
    end
  end
end
