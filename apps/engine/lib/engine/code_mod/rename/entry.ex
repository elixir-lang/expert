defmodule Engine.CodeMod.Rename.Entry do
  @moduledoc """
  An entry wrapper for search indexer entries used in rename operations.
  """
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry, as: IndexerEntry

  @type t :: %__MODULE__{
          id: IndexerEntry.entry_id(),
          path: Forge.path(),
          subject: IndexerEntry.subject(),
          block_range: Range.t() | nil,
          range: Range.t(),
          subtype: IndexerEntry.entry_subtype()
        }

  defstruct [
    :id,
    :path,
    :subject,
    :block_range,
    :range,
    :subtype
  ]

  @spec new(IndexerEntry.t()) :: t()
  def new(%IndexerEntry{} = indexer_entry) do
    %__MODULE__{
      id: indexer_entry.id,
      path: indexer_entry.path,
      subject: indexer_entry.subject,
      subtype: indexer_entry.subtype,
      block_range: indexer_entry.block_range,
      range: indexer_entry.range
    }
  end
end
