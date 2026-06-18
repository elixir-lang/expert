defmodule Engine.Commands.ReindexTest do
  use ExUnit.Case
  use Patch

  import Engine.Test.Entry.Builder
  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Engine.Commands.Reindex
  alias Engine.Search
  alias Forge.Document

  setup context do
    debounce_interval_millis = Map.get(context, :debounce_interval_millis, 0)
    test_pid = self()

    reindex_fun = fn _ ->
      test_ref = Process.monitor(test_pid)
      send(test_pid, {:reindex_started, self()})

      receive do
        :complete_reindex ->
          Process.demonitor(test_ref, [:flush])

        {:DOWN, ^test_ref, :process, ^test_pid, _reason} ->
          :ok
      end
    end

    start_supervised!(
      {Reindex, reindex_fun: reindex_fun, debounce_interval_millis: debounce_interval_millis}
    )

    {:ok, project: project()}
  end

  test "it should allow reindexing", %{project: project} do
    assert :ok = Reindex.perform(project)
    reindex_pid = await_reindex_started()
    assert Reindex.running?()
    complete_reindex(reindex_pid)
  end

  test "it fails if another index is running", %{project: project} do
    assert :ok = Reindex.perform(project)
    reindex_pid = await_reindex_started()
    assert {:error, "Already Running"} = Reindex.perform(project)
    complete_reindex(reindex_pid)
  end

  test "it eventually becomes available", %{project: project} do
    assert :ok = Reindex.perform(project)
    await_reindex_started() |> complete_reindex()
    refute_eventually Reindex.running?()
  end

  test "another reindex can be enqueued", %{project: project} do
    assert :ok = Reindex.perform(project)
    await_reindex_started() |> complete_reindex()
    assert_eventually :ok = Reindex.perform(project)
    await_reindex_started() |> complete_reindex()
  end

  defp await_reindex_started do
    assert_receive {:reindex_started, reindex_pid}
    reindex_pid
  end

  defp complete_reindex(reindex_pid) do
    send(reindex_pid, :complete_reindex)
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
      assert :ok = Reindex.perform(project)
      reindex_pid = await_reindex_started()

      Reindex.uri(uri)
      complete_reindex(reindex_pid)

      assert_receive {:entries, "/file.ex", ^new_entries}
    end
  end
end
