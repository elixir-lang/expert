defmodule Expert.Provider.Handlers.Formatting do
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Forge.Document.Changes
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  def handle(
        %Requests.TextDocumentFormatting{params: %Structures.DocumentFormattingParams{} = params},
        %Configuration{} = config
      ) do
    document = Forge.Document.Container.context_document(params, nil)

    case EngineApi.format(config.project, document) do
      {:ok, %Changes{} = document_edits} ->
        {:ok, document_edits}

      {:error, reason} ->
        Logger.error("Formatter failed #{inspect(reason)}")
        {:ok, nil}
    end
  end
end
