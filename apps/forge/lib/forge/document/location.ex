defmodule Forge.Document.Location do
  @moduledoc """
  A location in a document

  One of the fundamental LSP structures, this represents a subset of text in a document.
  The location is bounded by the given range, and the document can be given as a `Forge.Document`
  struct, or a uri referencing the document
  """
  use Forge.StructAccess

  alias Forge.Document
  alias Forge.Document.Range

  defstruct [:range, :document, :uri]

  @type t :: %__MODULE__{
          range: Range.t(),
          document: Document.t() | nil,
          uri: Forge.uri()
        }
  @spec new(Range.t(), Document.t() | String.t()) :: t()
  def new(%Range{} = range, %Document{} = document) do
    %__MODULE__{range: range, document: document, uri: document.uri}
  end

  def new(%Range{} = range, uri) when is_binary(uri) do
    %__MODULE__{range: range, uri: uri}
  end

  def uri(%__MODULE__{document: %Document{} = document}) do
    document.uri
  end

  @doc """
  Returns the location document's uri.
  """
  @spec uri(t) :: Forge.uri()
  def uri(%__MODULE__{} = location) do
    location.uri
  end
end
