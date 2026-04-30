defmodule Engine.Commands.ReindexTest do
  use ExUnit.Case
  use Patch

  import Engine.Test.Entry.Builder
  import Forge.EngineApi.Messages
  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Engine.Commands.Reindex
  alias Engine.Search
  alias Forge.Document

  setup context do
    case Map.get(context, :reindex_fun, :sleep) do
      :default ->
        start_supervised!(Reindex)

      :sleep ->
        start_supervised!({Reindex, reindex_fun: fn _ -> Process.sleep(20) end})

      :none ->
        :ok
    end

    {:ok, project: project()}
  end

  test "it should allow reindexing", %{project: project} do
    assert :ok = Reindex.perform(project)
    assert Reindex.running?()
  end

  test "it fails if another index is running", %{project: project} do
    assert :ok = Reindex.perform(project)
    assert {:error, "Already Running"} = Reindex.perform(project)
  end

  test "it eventually becomes available", %{project: project} do
    assert :ok = Reindex.perform(project)
    refute_eventually Reindex.running?()
  end

  test "another reindex can be enqueued", %{project: project} do
    assert :ok = Reindex.perform(project)
    assert_eventually :ok = Reindex.perform(project)
  end

  describe "uri/1" do
    setup do
      test = self()

      patch(Reindex.State, :entries_for_uri, fn uri ->
        entries =
          test
          |> Process.info()
          |> get_in([:dictionary])
          |> Enum.find_value(fn
            {^uri, value} -> value
            _ -> nil
          end)

        {:ok, Document.Path.ensure_path(uri), entries || []}
      end)

      patch(Search.Store, :update, fn uri, entries ->
        send(test, {:entries, uri, entries})
      end)

      :ok
    end

    test "reindexes a specific uri" do
      uri = "file:///file.ex"
      entries = [reference()]
      Process.put(uri, entries)
      Reindex.uri(uri)
      assert_receive {:entries, "/file.ex", ^entries}
    end

    test "buffers updates if a reindex is in progress", %{project: project} do
      uri = "file:///file.ex"
      new_entries = [reference(), definition()]
      Process.put(uri, new_entries)
      Reindex.perform(project)
      Reindex.uri(uri)

      assert_receive {:entries, "/file.ex", ^new_entries}
    end
  end

  describe "perform/1 with the default reindexer" do
    @tag reindex_fun: :default
    test "broadcasts success when rebuilding the search index succeeds", %{project: project} do
      test_pid = self()

      patch(Search.Store, :rebuild_index, fn ^project ->
        send(test_pid, :rebuild_index)
        :ok
      end)

      patch(Search.Store, :refresh_index, fn ^project ->
        send(test_pid, :refresh_index)
        :ok
      end)

      patch(Engine, :broadcast, fn message ->
        send(test_pid, {:broadcast, message})
        :ok
      end)

      assert :ok = Reindex.perform(project)

      assert_receive {:broadcast, project_reindex_requested(project: ^project)}
      assert_receive :rebuild_index
      assert_receive {:broadcast, project_reindexed(project: ^project, status: :success)}
      refute_receive :refresh_index
    end

    @tag reindex_fun: :default
    test "broadcasts the error when rebuilding the search index fails", %{project: project} do
      test_pid = self()

      patch(Search.Store, :rebuild_index, fn ^project -> {:error, :rebuild_failed} end)

      patch(Engine, :broadcast, fn message ->
        send(test_pid, {:broadcast, message})
        :ok
      end)

      assert :ok = Reindex.perform(project)

      assert_receive {:broadcast, project_reindex_requested(project: ^project)}

      assert_receive {:broadcast,
                      project_reindexed(project: ^project, status: {:error, :rebuild_failed})}
    end
  end
end
