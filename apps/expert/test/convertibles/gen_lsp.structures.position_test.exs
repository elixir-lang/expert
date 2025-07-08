defmodule GenLSP.Structures.Convertibles.PositionTest do
  alias GenLSP.Structures
  use Expert.Test.Protocol.ConvertibleSupport

  describe "to_lsp/2" do
    setup [:with_an_open_file]

    test "converts native position", %{uri: uri, document: document} do
      native_pos = valid_position(:native, document)
      assert {:ok, %Structures.Position{}} = to_lsp(native_pos, uri)
    end

    test "leaves protocol ranges alone", %{uri: uri} do
      lsp_pos = valid_position(:lsp)

      assert {:ok, ^lsp_pos} = to_lsp(lsp_pos, uri)
    end
  end

  describe "to_native/2" do
    setup [:with_an_open_file]

    test "converts lsp ranges", %{uri: uri} do
      proto_range = valid_position(:lsp)

      assert {:ok, %Document.Position{}} = to_native(proto_range, uri)
    end

    test "leaves native ranges alone", %{uri: uri, document: document} do
      native_range = valid_range(:native, document)
      assert {:ok, ^native_range} = to_native(native_range, uri)
    end
  end
end
