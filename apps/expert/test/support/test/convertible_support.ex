defmodule Expert.Test.Protocol.ConvertibleSupport do
  alias Forge.Document
  alias Forge.Protocol.Convertible

  use ExUnit.CaseTemplate

  using do
    quote location: :keep do
      alias GenLSP.Structures
      use Forge.Test.DocumentSupport

      def open_file_contents do
        "hello"
      end

      defoverridable open_file_contents: 0

      def to_lsp(convertible, uri) do
        Convertible.to_lsp(convertible)
      end

      def to_native(converible, uri) do
        {:ok, doc} = Document.Store.fetch(uri)
        Convertible.to_native(converible, doc)
      end

      def with_an_open_file(_) do
        {:ok, uri, document} = open_file(open_file_contents())
        {:ok, document: document, uri: uri}
      end

      def valid_range(:native, document) do
        start_pos = end_pos = valid_position(:native, document)
        range(:native, start_pos, end_pos)
      end

      def valid_range(:lsp) do
        start_pos = end_pos = valid_position(:lsp)
        %Structures.Range{start: start_pos, end: end_pos}
      end

      def range(:native, start_pos, end_pos) do
        Document.Range.new(start_pos, end_pos)
      end

      def range(:lsp, start_pos, end_pos) do
        %Structures.Range{start: start_pos, end: end_pos}
      end

      def valid_position(:native, document) do
        position(:native, document, 1, 1)
      end

      def valid_position(:lsp) do
        position(:lsp, 0, 0)
      end

      def position(:native, document, line, column) do
        Document.Position.new(document, line, column)
      end

      def position(:lsp, line, character) do
        %Structures.Position{line: line, character: character}
      end
    end
  end
end
