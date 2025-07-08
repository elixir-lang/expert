defmodule Forge.Protocol.Convertible.Document.ChangesTest do
  alias GenLSP.Structures
  use Expert.Test.Protocol.ConvertibleSupport

  describe "to_lsp/2" do
    setup [:with_an_open_file]

    test "converts to a list of text edits", %{uri: uri, document: document} do
      edit = Document.Edit.new("hi", valid_range(:native, document))
      document_edits = Document.Changes.new(document, [edit])

      assert {:ok, [%Structures.TextEdit{}]} = to_lsp(document_edits, uri)
    end

    test "uses the uri from the document edits", %{uri: uri} do
      # make a file with a couple lines and place a range on something other than the first line,
      # the default file only has one line so if this succeeds, we will ensure that we're using
      # the document edits' file.
      {:ok, _uri, document} = open_file("file:///other.ex", "several\nlines\nhere")

      edit =
        Document.Edit.new(
          "hi",
          range(:native, position(:native, document, 2, 1), position(:native, document, 2, 3))
        )

      document_edits = Document.Changes.new(document, [edit])

      assert {:ok, [%Structures.TextEdit{}]} = to_lsp(document_edits, uri)
    end
  end

  # to_native isn't tested because this is a native-only struct and can't come from the language server
end
