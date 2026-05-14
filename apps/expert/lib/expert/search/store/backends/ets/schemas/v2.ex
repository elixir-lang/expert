defmodule Expert.Search.Store.Backends.Ets.Schemas.V2 do
  use Expert.Search.Store.Backends.Ets.Schema, version: 2

  alias Forge.Search.Indexer.Entry

  require Entry

  defkey(:by_id, [:id, :type, :subtype])
  defkey(:by_subject, [:subject, :type, :subtype, :path])
  defkey(:by_path, [:path])
  defkey(:by_block_id, [:block_id, :path])
  defkey(:structure, [:path])

  def migrate(_), do: {:ok, []}

  def to_rows(%Entry{} = entry) when Entry.is_structure(entry) do
    [{structure(path: entry.path), entry.subject}]
  end

  def to_rows(%Entry{} = entry) do
    subject_key =
      by_subject(
        subject: to_subject(entry.subject),
        type: entry.type,
        subtype: entry.subtype,
        path: entry.path
      )

    id_key = by_id(id: entry.id, type: entry.type, subtype: entry.subtype)
    path_key = by_path(path: entry.path)
    block_key = by_block_id(path: entry.path, block_id: entry.block_id)

    [{id_key, entry}, {subject_key, id_key}, {path_key, id_key}, {block_key, id_key}]
  end

  def to_rows(%{type: _, subtype: _, id: _} = entry) do
    entry
    |> Map.delete(:__struct__)
    |> then(&struct(Entry, &1))
    |> to_rows()
  end

  def table_options, do: [:ordered_set]

  defp to_subject(binary) when is_binary(binary), do: binary
  defp to_subject(:_), do: :_
  defp to_subject(atom) when is_atom(atom), do: inspect(atom)
  defp to_subject(other), do: to_string(other)
end
