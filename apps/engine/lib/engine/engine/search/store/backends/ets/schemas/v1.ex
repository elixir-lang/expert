defmodule Engine.Search.Store.Backends.Ets.Schemas.V1 do
  @moduledoc """
  This schema  uses a bit of data duplication in order to achieve good performance.

  It does this by storing data under three different key types. The first type groups references to ids by
  path, and is accessible via the `by_path` utility macros. The second, stores data by subject, type, subtype,
  path and the elixir and erlang versions. This is what powers exact matching.
  Finally, entries are stored by their id, which powers direct lookups, which are used in fuzzy matching.

  """

  alias Engine.Search.Store.Backends.Ets.Schema
  alias Forge.Search.Indexer.Entry

  use Schema, version: 1

  defkey :by_id, [:id, :type, :subtype]

  defkey :by_subject, [
    :subject,
    :type,
    :subtype,
    :path
  ]

  defkey :by_path, [:path]

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

    id_key =
      by_id(
        id: entry.id,
        type: entry.type,
        subtype: entry.subtype
      )

    path_key = by_path(path: entry.path)

    [{subject_key, id_key}, {id_key, entry}, {path_key, id_key}]
  end

  # This case will handle any namespaced entries
  def to_rows(%{type: _, subtype: _, id: _} = entry) do
    map = Map.delete(entry, :__struct__)

    Entry
    |> struct(map)
    |> to_rows()
  end

  def table_options do
    [:named_table, :ordered_set]
  end

  defp to_subject(binary) when is_binary(binary), do: binary
  defp to_subject(:_), do: :_
  defp to_subject(atom) when is_atom(atom), do: inspect(atom)
  defp to_subject(other), do: to_string(other)
end
