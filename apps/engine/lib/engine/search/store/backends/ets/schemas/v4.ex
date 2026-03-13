defmodule Engine.Search.Store.Backends.Ets.Schemas.V4 do
  @moduledoc """
  V4 of the schema is the same as v3, but some releases had duplicate
  IDs. This schema just causes a reindex so we remove them entirely
  """
  use Engine.Search.Store.Backends.Ets.Schema, version: 4

  alias Engine.Search.Store.Backends.Ets.Schemas.V3
  alias Forge.Search.Indexer.Entry

  require Entry

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

  defdelegate to_rows(entry), to: V3
  defdelegate table_options(), to: V3
  defdelegate to_subject(subject), to: V3

  def migrate(_) do
    {:ok, []}
  end
end
