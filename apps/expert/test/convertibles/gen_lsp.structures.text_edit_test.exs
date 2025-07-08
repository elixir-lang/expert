defmodule GenLSP.Structures.Convertibles.TextEditTest do
  use Expert.Test.Protocol.ConvertibleSupport

  describe "to_lsp/2)" do
    setup [:with_an_open_file]

    test "leaves text edits alone", %{uri: uri} do
      native_text_edit = %Structures.TextEdit{new_text: "hi", range: valid_range(:lsp)}
      assert {:ok, ^native_text_edit} = to_lsp(native_text_edit, uri)
    end

    test "converts native positions in text edits", %{uri: uri, document: document} do
      text_edit =
        %Structures.TextEdit{
          new_text: "hi",
          range: range(:lsp, valid_position(:native, document), valid_position(:lsp))
        }

      assert %Document.Position{} = text_edit.range.start
      assert {:ok, converted} = to_lsp(text_edit, uri)
      assert %Structures.Position{} = converted.range.start
    end

    test "converts native ranges in text edits", %{uri: uri, document: document} do
      text_edit = %Structures.TextEdit{new_text: "hi", range: valid_range(:native, document)}
      assert %Document.Range{} = text_edit.range

      assert {:ok, converted} = to_lsp(text_edit, uri)
      assert %Structures.Range{} = converted.range
      assert %Structures.Position{} = converted.range.start
      assert %Structures.Position{} = converted.range.end
    end
  end

  describe "to_native/2" do
    setup [:with_an_open_file]

    test "converts to edits", %{uri: uri} do
      text_edit = %Structures.TextEdit{new_text: "Hi", range: valid_range(:lsp)}

      {:ok, converted} = to_native(text_edit, uri)

      assert %Document.Edit{} = converted
      assert %Document.Range{} = converted.range
      assert %Document.Position{} = converted.range.start
      assert %Document.Position{} = converted.range.end
      assert "Hi" == converted.text
    end

    test "fails conversion gracefully", %{uri: uri} do
      edit =
        %Structures.TextEdit{
          new_text: "hi",
          range: range(:lsp, position(:lsp, -1, 0), valid_position(:lsp))
        }

      assert {:error, {:invalid_range, _}} = to_native(edit, uri)
    end
  end
end
