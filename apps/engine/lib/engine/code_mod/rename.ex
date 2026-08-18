defmodule Engine.CodeMod.Rename do
  @moduledoc """
  Entry point for rename operations.

  This module provides the main API for renaming entities (currently modules)
  in Elixir code. It coordinates between the preparation phase and the actual
  rename execution.
  """
  import Forge.EngineApi.Messages

  alias Engine.CodeMod.Rename
  alias Engine.Commands
  alias Engine.Progress
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range

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

  """
  @spec rename(Analysis.t(), Position.t(), String.t(), String.t() | nil) ::
          {:ok, [Document.Changes.t()]} | {:error, term()}
  def rename(%Analysis{} = analysis, %Position{} = position, new_name, _client_name) do
    if Process.whereis(Commands.Rename) do
      {:error, :rename_in_progress}
    else
      with {:ok, {renamable, entity}, range} <- Rename.Prepare.resolve(analysis, position) do
        rename_module = Map.fetch!(@rename_mappings, renamable)
        results = rename_module.rename(range, new_name, entity)

        with :ok <- set_rename_progress(results) do
          {:ok, results}
        end
      end
    end
  end

  defp set_rename_progress([]), do: :ok

  # Progress tracking is optional - if the infrastructure isn't running
  # (e.g., in tests), we just skip it silently
  defp set_rename_progress(document_changes_list) do
    case do_set_rename_progress(document_changes_list) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> {:error, :rename_in_progress}
      {:error, {:already_buffering, _pid}} -> {:error, :rename_in_progress}
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp do_set_rename_progress(document_changes_list) do
    uri_to_expected_operation = uri_to_expected_operation(document_changes_list)

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

    case Commands.RenameSupervisor.start_renaming(
           uri_to_expected_operation,
           paths_to_reindex,
           paths_to_delete,
           on_update_progress,
           on_complete
         ) do
      {:ok, _pid} = result ->
        result

      {:error, _reason} = error ->
        on_complete.()
        error
    end
  end

  defp uri_to_expected_operation(document_changes_list) do
    document_changes_list
    |> Map.new(fn %Document.Changes{document: document, rename_file: rename_file} ->
      uri = if rename_file, do: rename_file.new_uri, else: document.uri
      {uri, file_saved(uri: uri)}
    end)
  end
end
