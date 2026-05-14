defmodule Expert.Search.Store.Backends.Ets.Schemas.V1 do
  use Expert.Search.Store.Backends.Ets.Schema, version: 1

  alias Expert.Search.Store.Backends.Ets.Schema
  alias Forge.Search.Indexer.Entry

  defkey(:by_id, [:id, :type, :subtype])
  defkey(:by_subject, [:subject, :type, :subtype, :path])
  defkey(:by_path, [:path])

  def migrate(entries) do
    migrated =
      entries
      |> Stream.filter(fn
        {_, %_{type: _, subtype: _, id: _}} -> true
        _ -> false
      end)
      |> Stream.map(fn {_, entry} -> entry end)
      |> Schema.entries_to_rows(__MODULE__)

    {:ok, migrated}
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

    [{subject_key, id_key}, {id_key, entry}, {path_key, id_key}]
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
