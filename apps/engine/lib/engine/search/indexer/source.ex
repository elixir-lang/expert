defmodule Engine.Search.Indexer.Source do
  alias Engine.Search.Indexer
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Search.Indexer.Entry

  def index(path, source, extractors \\ nil) do
    path
    |> Document.new(source, 1)
    |> index_document(extractors)
  end

  def index_document(%Document{} = document, extractors \\ nil) do
    with {:ok, entries} <- document |> Ast.analyze() |> Indexer.Quoted.index(extractors) do
      {:ok, dedupe_search_definitions(entries)}
    end
  end

  defp dedupe_search_definitions(entries) do
    {deduped_entries, _seen} = Enum.reduce(entries, {[], MapSet.new()}, &dedupe_entry/2)

    Enum.reverse(deduped_entries)
  end

  defp dedupe_entry(entry, {entries, seen}) do
    case search_definition_key(entry) do
      nil ->
        {[entry | entries], seen}

      key ->
        if MapSet.member?(seen, key) do
          {entries, seen}
        else
          {[entry | entries], MapSet.put(seen, key)}
        end
    end
  end

  defp search_definition_key(%Entry{
         path: path,
         block_id: block_id,
         range: range,
         subject: subject,
         subtype: :definition,
         type: {kind, _} = type
       })
       when kind in [:function, :macro] do
    {path, block_id, subject, type, range_key(range)}
  end

  defp search_definition_key(_entry), do: nil

  defp range_key(%Forge.Document.Range{start: start, end: finish}) do
    {start.line, start.character, finish.line, finish.character}
  end

  defp range_key(_range), do: nil
end
