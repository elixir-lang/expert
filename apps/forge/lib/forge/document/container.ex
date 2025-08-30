defprotocol Forge.Document.Container do
  @moduledoc """
  A protocol used to find relevant documents in structs

  When converting positions from lsp formats to native and vice versa, you need the
  line of text from the relevant document. However, due to the nature of the protocol
  structs, there isn't a single place where the document (or a reference) to the document
  sits. This protocol allows generic access to the relevant document regardless of the
  structure.

  Note: This protocol only needs to be implemented for structs that don't have a `document`
  field, or don't have a `text_document` field with a `uri` sub-field. The following structs
  would _not_ need an implementation:

  ```
  %MyStruct{document: %Forge.Document{}}
  %MyStruct{text_document: %{uri: "file:///path/to/document.ex"}}
  ```
  """
  alias Forge.Document
  @fallback_to_any true
  @type maybe_context_document :: Document.t() | nil

  @spec context_document(t, maybe_context_document()) :: maybe_context_document()
  def context_document(t, parent_context_document)
end

defimpl Forge.Document.Container, for: Any do
  alias Forge.Document

  def context_document(%{document: %Document{} = document}, _) do
    document
  end

  def context_document(%{lsp: lsp_request}, parent_context_document) do
    context_document(lsp_request, parent_context_document)
  end

  def context_document(%{params: params}, parent_context_document) do
    context_document(params, parent_context_document)
  end

  def context_document(%{text_document: %{uri: uri}}, parent_context_document) do
    case Document.Store.fetch(uri) do
      {:ok, document} -> document
      _ -> parent_context_document
    end
  end

  def context_document(%{uri: uri}, parent_context_document) when is_binary(uri) do
    case Document.Store.fetch(uri) do
      {:ok, document} -> document
      _ -> parent_context_document
    end
  end

  def context_document(_, parent_context_document) do
    parent_context_document
  end
end
