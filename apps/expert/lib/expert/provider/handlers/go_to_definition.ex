defmodule Expert.Provider.Handlers.GoToDefinition do
  alias Expert.Configuration
  alias Expert.EngineApi
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  def handle(
        %Requests.TextDocumentDefinition{
          params: %Structures.DefinitionParams{} = params
        },
        %Configuration{} = config
      ) do
    document = Forge.Document.Container.context_document(params, nil)

    case EngineApi.definition(config.project, document, params.position) do
      {:ok, native_location} ->
        {:ok, native_location}

      {:error, reason} ->
        Logger.error("GoToDefinition failed: #{inspect(reason)}")
        {:ok, nil}
    end
  end
end
