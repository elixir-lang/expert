defmodule Expert.Provider.Handlers.Rename do
  @moduledoc """
  Handler for textDocument/rename requests.

  This handler executes the rename operation and returns the workspace edit
  containing all the text edits needed.
  """
  @behaviour Expert.Provider.Handler

  alias Expert.Configuration
  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Document.Changes
  alias Forge.Protocol.Convertible
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def handle(
        %GenLSP.Requests.TextDocumentRename{
          params: %Structures.RenameParams{} = params
        },
        %Context{} = context
      ) do
    %Context{document: document, project: project} = context

    case Document.Store.fetch(document.uri, :analysis) do
      {:ok, _document, %Ast.Analysis{valid?: true} = analysis} ->
        rename(project, analysis, params.position, params.new_name)

      _ ->
        {:error, :request_failed, "Document cannot be analyzed"}
    end
  end

  defp rename(project, analysis, position, new_name) do
    %Configuration{client_name: client_name} = Configuration.get()

    case EngineApi.rename(project, analysis, position, new_name, client_name) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, results} ->
        with {:ok, document_changes} <- to_document_changes(results) do
          {:ok, %Structures.WorkspaceEdit{document_changes: document_changes}}
        end

      {:error, {:unsupported_entity, entity}} ->
        Logger.info("Cannot rename entity: #{inspect(entity)}")
        {:ok, nil}

      {:error, reason} ->
        {:error, :request_failed, inspect(reason)}
    end
  end

  defp to_document_changes(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn changes, {:ok, acc} ->
      case to_text_document_edit(changes) do
        {:ok, edit} -> {:cont, {:ok, [edit | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, edits} -> {:ok, Enum.reverse(edits)}
      error -> error
    end
  end

  defp to_text_document_edit(%Changes{document: document, edits: edits}) do
    with {:ok, text_edits} <- Convertible.to_lsp(edits) do
      text_document = %Structures.OptionalVersionedTextDocumentIdentifier{
        uri: document.uri,
        version: document.version
      }

      {:ok,
       %Structures.TextDocumentEdit{
         edits: text_edits,
         text_document: text_document
       }}
    end
  end
end
