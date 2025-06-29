defmodule Engine.Test.Entry.Builder do
  alias Forge.Document.Range
  alias Forge.Identifier
  alias Forge.Search.Indexer.Entry

  import Forge.Test.PositionSupport

  def entry(fields \\ []) do
    defaults = [
      block_id: Identifier.next_global!(),
      id: Identifier.next_global!(),
      path: "/foo/bar/baz.ex",
      range: range(1, 1, 1, 5),
      subject: Module,
      type: :module,
      application: :engine
    ]

    fields = Keyword.merge(defaults, fields)

    struct!(Entry, fields)
  end

  def definition(fields \\ []) do
    fields
    |> Keyword.put(:subtype, :definition)
    |> entry()
  end

  def reference(fields \\ []) do
    fields
    |> Keyword.put(:subtype, :reference)
    |> entry()
  end

  def structure(fields \\ []) do
    path = Keyword.get(fields, :path, "/path/to/file.ex")
    structure = Keyword.get(fields, :structure, %{root: %{}})
    Entry.block_structure(path, structure)
  end

  defp range(start_line, start_column, end_line, end_column) do
    Range.new(position(start_line, start_column), position(end_line, end_column))
  end
end
