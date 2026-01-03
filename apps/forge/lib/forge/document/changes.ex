defmodule Forge.Document.Changes do
  @moduledoc """
  A `Forge.Document.Container` for text edits.

  This struct is helpful if you need to express one or several text edits in an LSP response.
  It will convert cleanly into either a single `TextEdit` or a list of `TextEdit`s depending on
  whether you passed a single edit or a list of edits.

  Using this struct allows efficient conversions at the language server border, as the document
  doesn't have to be looked up (and possibly read off the filesystem) by the language server.
  """
  defstruct [:document, :edits, :rename_file]
  alias Forge.Document

  use Forge.StructAccess

  defmodule RenameFile do
    @moduledoc """
    Represents a file rename operation during module renaming.
    """
    defstruct [:old_uri, :new_uri]

    @type t :: %__MODULE__{
            old_uri: Forge.uri(),
            new_uri: Forge.uri()
          }

    @spec new(Forge.uri(), Forge.uri()) :: t()
    def new(old_uri, new_uri) do
      %__MODULE__{old_uri: old_uri, new_uri: new_uri}
    end
  end

  @type edits :: Document.Edit.t() | [Document.Edit.t()]
  @type rename_file :: RenameFile.t() | nil
  @type t :: %__MODULE__{
          document: Document.t(),
          edits: edits,
          rename_file: rename_file
        }

  @doc """
  Creates a new Changes struct given a document and edits.

  """
  @spec new(Document.t(), edits(), rename_file()) :: t()
  def new(document, edits, rename_file \\ nil) do
    %__MODULE__{document: document, edits: edits, rename_file: rename_file}
  end
end
