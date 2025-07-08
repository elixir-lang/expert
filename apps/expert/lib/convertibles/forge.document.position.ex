defimpl Forge.Protocol.Convertible, for: Forge.Document.Position do
  alias Expert.Protocol.Conversions
  alias Forge.Document

  def to_lsp(%Document.Position{} = position) do
    Conversions.to_lsp(position)
  end

  def to_native(%Document.Position{} = position, _context_document) do
    {:ok, position}
  end
end
