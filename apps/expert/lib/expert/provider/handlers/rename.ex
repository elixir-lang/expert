defmodule Expert.Provider.Handlers.Rename do
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Forge.Document.Changes
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentRename{params: %Structures.RenameParams{} = params},
        %Context{} = context
      ) do
    %Context{document: document, project: project} = context

    case EngineApi.rename(project, document, params.position, params.new_name) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %Changes{} = changes} ->
        workspace_edit = %Structures.WorkspaceEdit{
          changes: %{document.uri => changes.edits}
        }

        {:ok, workspace_edit}

      {:error, reason} ->
        Logger.error("Rename failed: #{inspect(reason)}")
        {:ok, nil}
    end
  end
end
