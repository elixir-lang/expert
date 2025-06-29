defmodule Engine.Commands.ReindexTest do
  alias Engine.Commands.Reindex
  alias Engine.Search
  alias Forge.Document

  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures
  import Engine.Test.Entry.Builder

  use ExUnit.Case
  use Patch

  setup do
    reindex_fun = fn _ ->
      Process.sleep(20)
    end

    start_supervised!({Reindex, reindex_fun: reindex_fun})

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

  def put_entries(uri, entries) do
    Process.put(uri, entries)
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
      put_entries(uri, entries)
      Reindex.uri(uri)
      assert_receive {:entries, "/file.ex", ^entries}
    end

    test "buffers updates if a reindex is in progress", %{project: project} do
      uri = "file:///file.ex"
      new_entries = [reference(), definition()]
      put_entries(uri, new_entries)
      Reindex.perform(project)
      Reindex.uri(uri)

      assert_receive {:entries, "/file.ex", ^new_entries}
    end
  end
end
