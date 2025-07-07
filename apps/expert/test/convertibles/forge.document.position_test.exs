defmodule Forge.Protocol.Convertibles.PositionTest do
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

    test "converts valid positions", %{uri: uri, document: document} do
      assert {:ok, %Structures.Position{} = pos} = to_lsp(valid_position(:native, document), uri)
      assert pos.line == 0
      assert pos.character == 0
    end

    test "converts positions in other structs", %{uri: uri, document: document} do
      nested = %Outer{
        inner: %Inner{position: valid_position(:native, document)}
      }

      assert {:ok, converted} = to_lsp(nested, uri)

      assert %Structures.Position{} = converted.inner.position
    end

    test "leaves protocol positions alone", %{uri: uri} do
      lsp_pos = valid_position(:lsp)
      assert {:ok, ^lsp_pos} = to_lsp(lsp_pos, uri)
    end
  end

  describe "to_native/2" do
    setup [:with_an_open_file]

    test "converts valid positions", %{uri: uri} do
      assert {:ok, %Document.Position{} = pos} =
               :lsp
               |> position(1, 0)
               |> to_native(uri)

      assert pos.line == 2
      assert pos.character == 1
    end

    test "converts positions in other structs", %{uri: uri} do
      nested = %Outer{
        inner: %Inner{position: valid_position(:lsp)}
      }

      assert {:ok, converted} = to_native(nested, uri)
      assert %Document.Position{} = converted.inner.position
    end

    test "leaves native positions alone", %{uri: uri, document: document} do
      native_pos = valid_position(:native, document)

      assert {:ok, ^native_pos} =
               :native
               |> valid_position(document)
               |> to_native(uri)
    end
  end
end
