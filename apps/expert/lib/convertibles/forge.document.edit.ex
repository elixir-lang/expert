defimpl Forge.Protocol.Convertible, for: Forge.Document.Edit do
  alias Expert.Protocol.Conversions
  alias Forge.Document
  alias GenLSP.Structures.TextEdit

  def to_lsp(%Document.Edit{range: nil} = edit) do
    {:ok, %TextEdit{new_text: edit.text, range: nil}}
  end

  def to_lsp(%Document.Edit{} = edit) do
    with {:ok, range} <- Conversions.to_lsp(edit.range) do
      {:ok, %TextEdit{new_text: edit.text, range: range}}
    end
  end

  def to_native(%Document.Edit{} = edit, _context_document) do
    {:ok, edit}
  end
end
