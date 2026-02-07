defmodule Expert.Provider.Handlers.PrepareRename do
  @moduledoc """
  Handler for textDocument/prepareRename requests.

  This handler determines if the entity at the cursor can be renamed
  and returns the range and placeholder text for the rename operation.
  """
  alias Expert.ActiveProjects
  alias Expert.EngineApi
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Project
  alias GenLSP.Structures

  require Logger

  def handle(%GenLSP.Requests.TextDocumentPrepareRename{
        params: %Structures.PrepareRenameParams{} = params
      }) do
    document = Forge.Document.Container.context_document(params, nil)
    projects = ActiveProjects.projects()
    project = Project.project_for_document(projects, document)

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
        # PrepareRenameResult is a type alias in GenLSP, return as map
        result = %{
          placeholder: placeholder,
          range: to_lsp_range(range)
        }

        {:ok, result}

      {:ok, nil} ->
        {:ok, nil}

      {:error, error} when is_binary(error) ->
        {:error, :request_failed, error}

      {:error, error} ->
        {:error, :request_failed, inspect(error)}
    end
  end

  defp to_lsp_range(%Forge.Document.Range{} = range) do
    %Structures.Range{
      start: to_lsp_position(range.start),
      end: to_lsp_position(range.end)
    }
  end

  defp to_lsp_position(%Forge.Document.Position{} = position) do
    %Structures.Position{
      line: position.line - 1,
      character: position.character - 1
    }
  end
end
