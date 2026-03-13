defmodule Forge.Document.Changes do
  @moduledoc """
  A `Forge.Document.Container` for text edits.

  This struct is helpful if you need to express one or several text edits in an LSP response.
  It will convert cleanly into either a single `TextEdit` or a list of `TextEdit`s depending on
  whether you passed a single edit or a list of edits.

  Using this struct allows efficient conversions at the language server border, as the document
  doesn't have to be looked up (and possibly read off the filesystem) by the language server.
  """
  use Forge.StructAccess

  alias Forge.Document

  defstruct [:document, :edits]
  @type edits :: Document.Edit.t() | [Document.Edit.t()]
  @type t :: %__MODULE__{
          document: Document.t(),
          edits: edits
        }

  @doc """
  Creates a new Changes struct given a document and edits.

  """
  @spec new(Document.t(), edits()) :: t()
  def new(document, edits) do
    %__MODULE__{document: document, edits: edits}
  end
end
