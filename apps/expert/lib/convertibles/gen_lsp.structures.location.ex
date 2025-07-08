defimpl Forge.Protocol.Convertible, for: GenLSP.Structures.Location do
  alias Forge.Document
  alias Forge.Document.Container
  alias Expert.Protocol.Conversions
  alias GenLSP.Structures

  def to_lsp(%Structures.Location{} = location) do
    with {:ok, range} <- Conversions.to_lsp(location.range) do
      {:ok, %Structures.Location{location | range: range}}
    end
  end

  def to_native(%Structures.Location{} = location, context_document) do
    context_document = Container.context_document(location, context_document)

    with {:ok, range} <- Conversions.to_elixir(location.range, context_document) do
      {:ok, Document.Location.new(range, context_document.uri)}
    end
  end
end
