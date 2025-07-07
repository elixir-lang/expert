defimpl Forge.Protocol.Convertible, for: Forge.Document.Changes do
  alias Forge.Document

  def to_lsp(%Document.Changes{} = changes) do
    Forge.Protocol.Convertible.to_lsp(changes.edits)
  end

  def to_native(%Document.Changes{} = changes, _) do
    {:ok, changes}
  end
end
