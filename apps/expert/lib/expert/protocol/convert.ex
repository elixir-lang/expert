defmodule Expert.Protocol.Convert do
  alias Forge.Document
  alias Forge.Protocol.Convertible

  def to_lsp(%_{result: result} = response) do
    case Convertible.to_lsp(result) do
      {:ok, converted} ->
        {:ok, Map.put(response, :result, converted)}

      error ->
        error
    end
  end

  def to_lsp(other) do
    Convertible.to_lsp(other)
  end

  def to_native(%{params: request_or_notification} = original_request) do
    context_document = Document.Container.context_document(request_or_notification, nil)

    with {:ok, native_request} <- Convertible.to_native(request_or_notification, context_document) do
      updated_request =
        case Map.merge(request_or_notification, Map.from_struct(native_request)) do
          %_{document: _} = updated -> Map.put(updated, :document, context_document)
          updated -> updated
        end

      {:ok, %{original_request | params: updated_request}}
    end
  end

  def to_native(%GenLSP.Requests.Shutdown{} = request) do
    # Special case for shutdown requests, which don't have a params field
    {:ok, request}
  end
end
