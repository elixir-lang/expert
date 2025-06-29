defmodule Forge.Search.Indexer.Source.Block do
  @moduledoc """
  A struct that represents a block of source code
  """

  defstruct [:starts_at, :ends_at, :id, :parent_id]
  alias Forge.Identifier

  def root do
    %__MODULE__{id: :root}
  end

  def new(starts_at, ends_at) do
    id = Identifier.next_global!()
    %__MODULE__{starts_at: starts_at, ends_at: ends_at, id: id}
  end
end
