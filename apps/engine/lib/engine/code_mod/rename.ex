defmodule Engine.CodeMod.Rename do
  @moduledoc """
  Entry point for rename operations.

  This module provides the main API for renaming entities (currently modules)
  in Elixir code. It coordinates between the preparation phase and the actual
  rename execution.
  """
  alias Engine.CodeMod.Rename
  alias Engine.Commands
  alias Engine.Progress
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

  import Forge.EngineApi.Messages

  @doc """
  Prepares a rename operation at the given position.

  Returns `{:ok, entity_name, range}` if the entity can be renamed,
  `{:ok, nil}` if at an unsupported location,
  or `{:error, reason}` if renaming is not possible.
  """
  @spec prepare(Analysis.t(), Position.t()) ::
          {:ok, String.t(), Range.t()} | {:ok, nil} | {:error, term()}
  defdelegate prepare(analysis, position), to: Rename.Prepare

  @rename_mappings %{module: Rename.Module}

  @doc """
  Executes a rename operation.

  Renames the entity at the given position to `new_name`, returning a list
  of document changes that should be applied.

  The `client_name` parameter is used to determine client-specific behavior
  for progress tracking (e.g., VSCode sends different events than Neovim).
  """
  @spec rename(Analysis.t(), Position.t(), String.t(), String.t() | nil) ::
          {:ok, [Document.Changes.t()]} | {:error, term()}
  def rename(%Analysis{} = analysis, %Position{} = position, new_name, client_name) do
    with {:ok, {renamable, entity}, range} <- Rename.Prepare.resolve(analysis, position) do
      rename_module = Map.fetch!(@rename_mappings, renamable)
      results = rename_module.rename(range, new_name, entity)
      set_rename_progress(results, client_name)
      {:ok, results}
    end
  end

  defp set_rename_progress(document_changes_list, client_name) do
    # Progress tracking is optional - if the infrastructure isn't running
    # (e.g., in tests), we just skip it silently
    try do
      do_set_rename_progress(document_changes_list, client_name)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp do_set_rename_progress(document_changes_list, client_name) do
    uri_to_expected_operation =
      uri_to_expected_operation(client_name, document_changes_list)

    {paths_to_delete, paths_to_reindex} =
      for %Document.Changes{rename_file: rename_file, document: document} <- document_changes_list do
        if rename_file do
          {rename_file.old_uri, rename_file.new_uri}
        else
          {nil, document.uri}
        end
      end
      |> Enum.unzip()

    paths_to_delete = Enum.reject(paths_to_delete, &is_nil/1)

    {on_update_progress, on_complete} =
      case Progress.begin("Renaming") do
        {:ok, token} ->
          {fn _delta, message -> Progress.report(token, message: message) end,
           fn -> Progress.complete(token) end}

        {:error, _} ->
          {fn _delta, _message -> :ok end, fn -> :ok end}
      end

    Commands.RenameSupervisor.start_renaming(
      uri_to_expected_operation,
      paths_to_reindex,
      paths_to_delete,
      on_update_progress,
      on_complete
    )
  end

  # VSCode sends both file_changed and file_saved events
  defp uri_to_expected_operation(client_name, document_changes_list)
       when client_name in ["Visual Studio Code"] do
    document_changes_list
    |> Enum.flat_map(fn %Document.Changes{document: document, rename_file: rename_file} ->
      if rename_file do
        # when the file is renamed, we won't receive `DidSave` for the old file
        [
          {rename_file.old_uri, file_changed(uri: rename_file.old_uri)},
          {rename_file.new_uri, file_saved(uri: rename_file.new_uri)}
        ]
      else
        [{document.uri, file_saved(uri: document.uri)}]
      end
    end)
    |> Map.new()
  end

  # Other editors (like Neovim) may only send file_changed events
  defp uri_to_expected_operation(_, document_changes_list) do
    document_changes_list
    |> Enum.flat_map(fn %Document.Changes{document: document, rename_file: rename_file} ->
      if rename_file do
        [{rename_file.new_uri, file_saved(uri: rename_file.new_uri)}]
      else
        # Some editors do not directly save the file after renaming, such as *neovim*.
        # when the file is not renamed, we'll only received `DidChange` for the old file
        [{document.uri, file_changed(uri: document.uri)}]
      end
    end)
    |> Map.new()
  end
end
