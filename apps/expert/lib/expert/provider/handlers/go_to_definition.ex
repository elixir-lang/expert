defmodule Expert.Provider.Handlers.GoToDefinition do
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentDefinition{params: %Structures.DefinitionParams{} = params},
        %Context{kind: :project} = context
      ) do
    %Context{document: document, project: project} = context

    case EngineApi.definition(project, document, params.position) do
      {:ok, native_location} ->
        {:ok, native_location}

      {:error, reason} ->
        Logger.error("GoToDefinition failed: #{inspect(reason)}")
        {:ok, nil}
    end
  end

  def handle(%Requests.TextDocumentDefinition{}, %Context{kind: :bare}) do
    {:ok, nil}
  end
end
