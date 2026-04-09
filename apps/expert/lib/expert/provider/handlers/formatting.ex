defmodule Expert.Provider.Handlers.Formatting do
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Forge.Document.Changes
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentFormatting{
          params: %Structures.DocumentFormattingParams{}
        },
        %Context{kind: :project} = context
      ) do
    %Context{document: document, project: project} = context

    case EngineApi.format(project, document) do
      {:ok, %Changes{} = document_edits} ->
        {:ok, document_edits}

      {:error, reason} ->
        Logger.error("Formatter failed #{inspect(reason)}")
        {:ok, nil}
    end
  end

  def handle(%Requests.TextDocumentFormatting{}, %Context{kind: :bare}) do
    {:ok, nil}
  end
end
