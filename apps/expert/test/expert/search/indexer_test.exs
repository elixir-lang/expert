defmodule Expert.Search.IndexerTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Search.Indexer

  setup do
    {:ok, project: project()}
  end

  test "create_index/1 commits the returned manifest on the engine node", %{project: project} do
    test_pid = self()

    patch(EngineApi, :call, fn
      ^project, Engine.Search.Indexer, :create_index, [^project] ->
        {:ok, [:entry], :manifest}

      ^project, Engine.Search.Indexer, :commit_manifest, [^project, :manifest] ->
        send(test_pid, :commit_manifest)
        :ok
    end)

    assert {:ok, [:entry], after_apply} = Indexer.create_index(project)
    refute_receive :commit_manifest

    assert :ok = after_apply.()
    assert_receive :commit_manifest
  end

  test "update_index/2 commits the returned manifest on the engine node", %{project: project} do
    test_pid = self()
    cleared_path = Path.join(Forge.Project.root_path(project), "lib/file.ex")
    path_to_ids = %{cleared_path => 1}

    patch(EngineApi, :call, fn
      ^project, Engine.Search.Indexer, :update_index, [^project, ^path_to_ids] ->
        {:ok, [:entry], [cleared_path], :manifest}

      ^project, Engine.Search.Indexer, :commit_manifest, [^project, :manifest] ->
        send(test_pid, :commit_manifest)
        :ok
    end)

    assert {:ok, [:entry], [^cleared_path], after_apply} =
             Indexer.update_index(project, path_to_ids)

    refute_receive :commit_manifest

    assert :ok = after_apply.()
    assert_receive :commit_manifest
  end
end
