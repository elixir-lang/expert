defmodule Expert.Search.Store.Backends.Ets.Schemas.LegacyV0 do
  @moduledoc """
  Legacy pre-versioned schema marker.
  """

  use Expert.Search.Store.Backends.Ets.Schema, version: 0

  def index_file_name, do: "source.index.ets"
  def to_rows(_), do: []
end
