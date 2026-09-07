defimpl Forge.Protocol.Convertible, for: GenLSP.Structures.DidChangeTextDocumentParams do
  alias GenLSP.Structures.DidChangeTextDocumentParams

  def to_native(%DidChangeTextDocumentParams{} = params, _context_document) do
    {:ok, params}
  end

  def to_lsp(%DidChangeTextDocumentParams{} = params) do
    {:ok, params}
  end
end
