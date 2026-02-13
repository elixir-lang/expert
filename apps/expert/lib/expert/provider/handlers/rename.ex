defmodule Expert.Provider.Handlers.Rename do
  @moduledoc """
  Handler for textDocument/rename requests.

  This handler executes the rename operation and returns the workspace edit
  containing all the text edits and file renames needed.
  """
  alias Expert.ActiveProjects
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Document.Changes
  alias Forge.Project
  alias GenLSP.Structures

  require Logger

  def handle(%GenLSP.Requests.TextDocumentRename{
        params: %Structures.RenameParams{} = params
      }) do
    document = Forge.Document.Container.context_document(params, nil)
    projects = ActiveProjects.projects()
    project = Project.project_for_document(projects, document)

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
        document_changes =
          Enum.flat_map(results, fn
            %Changes{rename_file: %Changes.RenameFile{}} = changes ->
              [to_text_document_edit(changes), to_rename_file(changes.rename_file)]

            %Changes{} = changes ->
              [to_text_document_edit(changes)]
          end)

        workspace_edit = %Structures.WorkspaceEdit{document_changes: document_changes}
        {:ok, workspace_edit}

      {:error, {:unsupported_entity, entity}} ->
        Logger.info("Cannot rename entity: #{inspect(entity)}")
        {:ok, nil}

      {:error, reason} ->
        {:error, :request_failed, inspect(reason)}
    end
  end

  defp to_text_document_edit(%Changes{} = changes) do
    %Changes{document: document, edits: edits} = changes

    text_document =
      %Structures.OptionalVersionedTextDocumentIdentifier{
        uri: document.uri,
        version: document.version
      }

    %Structures.TextDocumentEdit{
      edits: Enum.map(edits, &to_text_edit/1),
      text_document: text_document
    }
  end

  defp to_text_edit(%Document.Edit{} = edit) do
    %Structures.TextEdit{
      new_text: edit.text,
      range: to_lsp_range(edit.range)
    }
  end

  defp to_lsp_range(%Document.Range{} = range) do
    %Structures.Range{
      start: to_lsp_position(range.start),
      end: to_lsp_position(range.end)
    }
  end

  defp to_lsp_position(%Document.Position{} = position) do
    %Structures.Position{
      line: position.line - 1,
      character: position.character - 1
    }
  end

  defp to_rename_file(%Changes.RenameFile{} = rename_file) do
    %Structures.RenameFile{
      kind: "rename",
      new_uri: rename_file.new_uri,
      old_uri: rename_file.old_uri,
      options: %Structures.RenameFileOptions{overwrite: true}
    }
  end
end
