defmodule Expert.Provider.Handlers.PrepareRename do
  @moduledoc """
  Handler for textDocument/prepareRename requests.

  This handler determines if the entity at the cursor can be renamed
  and returns the range and placeholder text for the rename operation.
  """
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Protocol.Convertible
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def handle(
        %GenLSP.Requests.TextDocumentPrepareRename{
          params: %Structures.PrepareRenameParams{} = params
        },
        %Context{} = context
      ) do
    %Context{document: document, project: project} = context

    case Document.Store.fetch(document.uri, :analysis) do
      {:ok, _document, %Ast.Analysis{valid?: true} = analysis} ->
        prepare_rename(project, analysis, params.position)

      _ ->
        {:error, :request_failed, "Document cannot be analyzed"}
    end
  end

  defp prepare_rename(project, analysis, position) do
    case EngineApi.prepare_rename(project, analysis, position) do
      {:ok, placeholder, range} when is_binary(placeholder) ->
        with {:ok, lsp_range} <- Convertible.to_lsp(range) do
          {:ok, %{range: lsp_range, placeholder: placeholder}}
        end

      {:ok, nil} ->
        {:ok, nil}

      {:error, error} when is_binary(error) ->
        {:error, :request_failed, error}

      {:error, error} ->
        {:error, :request_failed, inspect(error)}
    end
  end
end
