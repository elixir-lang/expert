defmodule Engine.CodeMod.Rename.Entry do
  @moduledoc """
  An entry wrapper for search indexer entries used in rename operations.

  When renaming, we rely on the `Forge.Search.Indexer.Entry`,
  and we also need some other fields used exclusively for renaming, such as `edit_range`.
  """
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry, as: IndexerEntry

  @type t :: %__MODULE__{
          id: IndexerEntry.entry_id(),
          path: Forge.path(),
          subject: IndexerEntry.subject(),
          block_range: Range.t() | nil,
          range: Range.t(),
          edit_range: Range.t(),
          subtype: IndexerEntry.entry_subtype()
        }

  defstruct [
    :id,
    :path,
    :subject,
    :block_range,
    :range,
    :edit_range,
    :subtype
  ]

  @doc """
  Creates a new Entry from an IndexerEntry.
  """
  @spec new(IndexerEntry.t()) :: t()
  def new(%IndexerEntry{} = indexer_entry) do
    %__MODULE__{
      id: indexer_entry.id,
      path: indexer_entry.path,
      subject: indexer_entry.subject,
      subtype: indexer_entry.subtype,
      block_range: indexer_entry.block_range,
      range: indexer_entry.range,
      edit_range: indexer_entry.range
    }
  end
end
