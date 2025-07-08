defimpl Forge.Protocol.Convertible, for: GenLSP.Structures.Range do
  alias GenLSP.Structures.Range
  alias GenLSP.Structures.Position
  alias Expert.Protocol.Conversions

  def to_lsp(%Range{} = range) do
    Conversions.to_lsp(range)
  end

  def to_native(
        %Range{
          start: %Position{line: start_line, character: start_character},
          end: %Position{line: end_line, character: end_character}
        } = range,
        _context_document
      )
      when start_line < 0 or start_character < 0 or end_line < 0 or end_character < 0 do
    {:error, {:invalid_range, range}}
  end

  def to_native(%Range{} = range, context_document) do
    Conversions.to_elixir(range, context_document)
  end
end
