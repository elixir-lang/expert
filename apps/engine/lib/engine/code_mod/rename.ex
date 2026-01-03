defmodule Engine.CodeMod.Rename do
  @moduledoc """
  Entry point for rename operations.

  This module provides the main API for renaming entities (currently modules)
  in Elixir code. It coordinates between the preparation phase and the actual
  rename execution.
  """
  alias Engine.CodeMod.Rename
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

  The `client_name` parameter is currently unused but reserved for future
  client-specific behavior (e.g., different progress tracking for VSCode vs Neovim).
  """
  @spec rename(Analysis.t(), Position.t(), String.t(), String.t() | nil) ::
          {:ok, [Document.Changes.t()]} | {:error, term()}
  def rename(%Analysis{} = analysis, %Position{} = position, new_name, _client_name) do
    with {:ok, {renamable, entity}, range} <- Rename.Prepare.resolve(analysis, position) do
      rename_module = Map.fetch!(@rename_mappings, renamable)
      results = rename_module.rename(range, new_name, entity)
      {:ok, results}
    end
  end
end
