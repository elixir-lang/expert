defimpl Forge.Protocol.Convertible, for: GenLSP.Structures.TextEdit do
  alias Forge.Document
  alias Expert.Protocol.Conversions
  alias GenLSP.Structures

  def to_lsp(%Structures.TextEdit{} = text_edit) do
    with {:ok, range} <- Conversions.to_lsp(text_edit.range) do
      {:ok, %Structures.TextEdit{text_edit | range: range}}
    end
  end

  def to_native(%Structures.TextEdit{range: nil} = text_edit, _context_document) do
    {:ok, Document.Edit.new(text_edit.new_text)}
  end

  def to_native(%Structures.TextEdit{} = text_edit, context_document) do
    with {:ok, %Document.Range{} = range} <-
           Conversions.to_elixir(text_edit.range, context_document) do
      {:ok, Document.Edit.new(text_edit.new_text, range)}
    end
  end
end
