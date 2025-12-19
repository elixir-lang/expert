defmodule Forge.Test.CodeMod.Case do
  alias Forge.CodeUnit
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
    utf8_edits = Enum.map(text_edits, &convert_edit_utf16_to_utf8(document, &1))
    {:ok, edited_document} = Document.apply_content_changes(document, 1, utf8_edits)
    edited_document = Document.to_string(edited_document)

    if Keyword.get(opts, :trim, true) do
      String.trim(edited_document)
    else
      edited_document
    end
  end

  defp convert_edit_utf16_to_utf8(document, %Document.Edit{} = edit) do
    case edit.range do
      nil ->
        edit

      range ->
        start_pos = convert_position_utf16_to_utf8(document, range.start)
        end_pos = convert_position_utf16_to_utf8(document, range.end)
        %{edit | range: %{range | start: start_pos, end: end_pos}}
    end
  end

  defp convert_position_utf16_to_utf8(document, %Document.Position{} = position) do
    case Document.fetch_text_at(document, position.line) do
      {:ok, line_text} ->
        case CodeUnit.utf16_offset_to_utf8_offset(line_text, position.character - 1) do
          {:ok, utf8_position} ->
            Document.Position.new(document, position.line, utf8_position)

          {:error, :out_of_bounds} ->
            Document.Position.new(document, position.line, byte_size(line_text) + 1)

          {:error, :misaligned} ->
            position
        end

      :error ->
        position
    end
  end
end
