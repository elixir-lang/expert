defimpl Forge.Protocol.Convertible, for: Forge.Document.Range do
  alias Expert.Protocol.Conversions
  alias Forge.Document

  def to_lsp(%Document.Range{} = range) do
    Conversions.to_lsp(range)
  end

  def to_native(%Document.Range{} = range, _context_document) do
    {:ok, range}
  end
end
