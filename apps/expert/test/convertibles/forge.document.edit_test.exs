defmodule Forge.Protocol.Convertibles.EditTest do
  alias GenLSP.Structures
  use Expert.Test.Protocol.ConvertibleSupport

  defmodule Inner do
    defstruct [:position]
  end

  defmodule Outer do
    defstruct [:inner]
  end

  describe "to_lsp/2" do
    setup [:with_an_open_file]

    test "leaves protocol text edits alone", %{uri: uri} do
      lsp_text_edit = %Structures.TextEdit{new_text: "hi", range: valid_range(:lsp)}
      {:ok, ^lsp_text_edit} = to_lsp(lsp_text_edit, uri)
    end

    test "converts with no range", %{uri: uri} do
      assert {:ok, %Structures.TextEdit{new_text: "hi"}} = to_lsp(Document.Edit.new("hi"), uri)
    end

    test "converts with a filled in range", %{uri: uri, document: document} do
      ex_range =
        range(:native, valid_position(:native, document), position(:native, document, 1, 3))

      assert {:ok, %Structures.TextEdit{} = text_edit} =
               to_lsp(Document.Edit.new("hi", ex_range), uri)

      assert text_edit.new_text == "hi"
      assert %Structures.Range{} = range = text_edit.range
      assert range.start.line == 0
      assert range.start.character == 0
      assert range.end.line == 0
      assert range.end.character == 2
    end
  end

  describe "to_native/2" do
    setup [:with_an_open_file]

    test "converts a text edit with no range", %{uri: uri} do
      proto_edit = %Structures.TextEdit{new_text: "hi", range: nil}

      assert {:ok, %Document.Edit{} = edit} = to_native(proto_edit, uri)

      assert edit.text == "hi"
      assert edit.range == nil
    end

    test "leaves native text edits alone", %{uri: uri, document: document} do
      native_text_edit = Document.Edit.new("hi", valid_range(:native, document))

      assert {:ok, ^native_text_edit} = to_native(native_text_edit, uri)
    end
  end
end
