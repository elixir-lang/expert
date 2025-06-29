defmodule Engine.Search.Store.Backends.Ets.Schemas.V3 do
  alias Engine.Search.Store.Backends.Ets.Schema
  alias Forge.Search.Indexer.Entry

  require Entry
  use Schema, version: 3

  defkey :by_id, [:id, :type, :subtype]

  defkey :by_subject, [
    :subject,
    :type,
    :subtype,
    :path
  ]

  defkey :by_path, [:path]
  defkey :by_block_id, [:block_id, :path]
  defkey :structure, [:path]

  def migrate(entries) do
    migrated =
      entries
      |> Stream.filter(fn
        {query_by_subject(), %Entry{}} -> true
        _ -> false
      end)
      |> Stream.map(fn {_, entry} -> entry end)
      |> Schema.entries_to_rows(__MODULE__)

    {:ok, migrated}
  end

  def to_rows(%Entry{} = entry) when Entry.is_structure(entry) do
    structure_key = structure(path: entry.path)
    [{structure_key, entry.subject}]
  end

  def to_rows(%Entry{} = entry) do
    subject_key =
      by_subject(
        subject: to_subject(entry.subject),
        type: entry.type,
        subtype: entry.subtype,
        path: entry.path
      )

    id_key =
      by_id(
        id: entry.id,
        type: entry.type,
        subtype: entry.subtype
      )

    path_key = by_path(path: entry.path)
    block_key = by_block_id(path: entry.path, block_id: entry.block_id)

    [{id_key, entry}, {subject_key, id_key}, {path_key, id_key}, {block_key, id_key}]
  end

  # This case will handle any namespaced entries
  def to_rows(%{type: _, subtype: _, id: _} = entry) do
    map = Map.delete(entry, :__struct__)

    Entry
    |> struct(map)
    |> to_rows()
  end

  def table_options do
    if Features.can_use_compressed_ets_table?() do
      [:named_table, :ordered_set, :compressed]
    else
      [:named_table, :ordered_set]
    end
  end

  def to_subject(charlist) when is_list(charlist), do: charlist
  def to_subject(:_), do: :_
  def to_subject(atom) when is_atom(atom), do: atom |> inspect() |> to_charlist()
  def to_subject(other), do: to_charlist(other)
end
