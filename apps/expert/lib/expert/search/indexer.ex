defmodule Expert.Search.Indexer do
  @moduledoc false

  alias Expert.EngineApi
  alias Forge.Project

  def create_index(%Project{} = project) do
    with {:ok, entries, manifest} <-
           EngineApi.call(project, Engine.Search.Indexer, :create_index, [project]) do
      {:ok, entries, fn -> commit_manifest(project, manifest) end}
    end
  end

  def update_index(%Project{} = project, path_to_ids) when is_map(path_to_ids) do
    with {:ok, updated_entries, paths_to_clear, manifest} <-
           EngineApi.call(project, Engine.Search.Indexer, :update_index, [project, path_to_ids]) do
      {:ok, updated_entries, paths_to_clear, fn -> commit_manifest(project, manifest) end}
    end
  end

  defp commit_manifest(%Project{} = project, manifest) do
    EngineApi.call(project, Engine.Search.Indexer, :commit_manifest, [project, manifest])
  end
end
