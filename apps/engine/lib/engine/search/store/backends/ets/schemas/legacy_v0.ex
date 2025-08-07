defmodule Engine.Search.Store.Backends.Ets.Schemas.LegacyV0 do
  @moduledoc """
  A legacy version of the schema.

  We pushed the initial indexer to main before we added schemas and versioning.
  This represents that schema type, hence the non-versioned name.
  """
  alias Engine.Search.Store.Backends.Ets.Schema

  use Schema, version: 0

  def index_file_name do
    "source.index.ets"
  end

  def to_rows(_) do
    []
  end
end
