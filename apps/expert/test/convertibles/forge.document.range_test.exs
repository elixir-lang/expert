defmodule Forge.Protocol.Convertibles.RangeTest do
  alias GenLSP.Structures
  use Expert.Test.Protocol.ConvertibleSupport

  describe "to_lsp/2" do
    setup [:with_an_open_file]

    test "converts ranges", %{uri: uri, document: document} do
      native_range =
        range(:native, position(:native, document, 1, 1), position(:native, document, 1, 3))

      assert {:ok, %Structures.Range{} = range} = to_lsp(native_range, uri)
      assert %Structures.Position{} = range.start
      assert %Structures.Position{} = range.end
    end

    test "leaves protocol ranges alone", %{uri: uri} do
      lsp_range = valid_range(:lsp)

      assert {:ok, ^lsp_range} = to_lsp(lsp_range, uri)
    end

    test "converts native positions inside lsp ranges", %{uri: uri, document: document} do
      lsp_range = range(:lsp, valid_position(:native, document), valid_position(:lsp))

      assert %Document.Position{} = lsp_range.start

      assert {:ok, %Structures.Range{} = converted} = to_lsp(lsp_range, uri)
      assert %Structures.Position{} = converted.start
      assert %Structures.Position{} = converted.end
    end
  end

  describe "to_native/2" do
    setup [:with_an_open_file]

    test "converts ranges", %{uri: uri} do
      proto_range = range(:lsp, position(:lsp, 0, 0), position(:lsp, 0, 3))

      assert {:ok, %Document.Range{} = range} = to_native(proto_range, uri)

      assert %Document.Position{} = range.start
      assert %Document.Position{} = range.end
    end

    test "leaves native ranges alone", %{uri: uri, document: document} do
      native_range = valid_range(:native, document)
      assert {:ok, ^native_range} = to_native(native_range, uri)
    end
  end
end
