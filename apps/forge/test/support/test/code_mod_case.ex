defmodule Forge.Test.CodeMod.Case do
  alias Forge.Document
  alias Forge.Test.CodeSigil

  use ExUnit.CaseTemplate

  using opts do
    convert_to_ast? = Keyword.get(opts, :enable_ast_conversion, true)

    quote do
      import Forge.Test.Fixtures
      import unquote(CodeSigil), only: [sigil_q: 2]

      def apply_code_mod(_, _, _) do
        {:error, "You must implement apply_code_mod/3"}
      end

      defoverridable apply_code_mod: 3

      def modify(original, options \\ []) do
        with {:ok, ast} <- maybe_convert_to_ast(original, options),
             {:ok, edits} <- apply_code_mod(original, ast, options) do
          {:ok, unquote(__MODULE__).apply_edits(original, edits, options)}
        end
      end

      defp maybe_convert_to_ast(code, options) do
        alias Forge.Ast

        if Keyword.get(options, :convert_to_ast, unquote(convert_to_ast?)) do
          case Ast.from(code) do
            {:ok, ast, _comments} -> {:ok, ast}
            other -> other
          end
        else
          {:ok, nil}
        end
      end
    end
  end

  def apply_edits(original, text_edits, opts) do
    document = Document.new("file:///file.ex", original, 0)
    {:ok, edited_document} = Document.apply_content_changes(document, 1, text_edits)
    edited_document = Document.to_string(edited_document)

    if Keyword.get(opts, :trim, true) do
      String.trim(edited_document)
    else
      edited_document
    end
  end
end
