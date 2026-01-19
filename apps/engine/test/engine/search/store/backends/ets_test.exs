defmodule Engine.Search.Store.Backend.EtsTest do
  alias Engine.Dispatch
  alias Engine.Search.Store
  alias Engine.Search.Store.Backends
  alias Engine.Test.Entry
  alias Forge.Project
  alias Forge.Test.EventualAssertions
  alias Forge.Test.Fixtures

  use ExUnit.Case, async: false
  use Patch

  import EventualAssertions
  import Entry.Builder
  import Fixtures

  setup do
    backend = Backends.Ets
    project = project()
    # These test cases require an clean slate going into them
    # so we should remove the indexes once when the tests start,
    # and again when tests end, so the next test has a clean slate.
    # Removing the index at the end will also let other test cases
    # start with a clean slate.

    Engine.set_project(project)

    patch(Dispatch, :erpc_call, fn Expert.Progress, :begin, [_title, _opts] ->
      {:ok, System.unique_integer([:positive])}
    end)

    patch(Dispatch, :erpc_cast, fn Expert.Progress, _function, _args -> true end)

    delete_indexes(project, backend)

    on_exit(fn ->
      delete_indexes(project, backend)
    end)

    {:ok, backend: backend, project: project}
  end

  def all_entries(backend) do
    backend.reduce([], fn entry, acc -> [entry | acc] end)
  end

  def delete_indexes(project, Backends.Ets) do
    Backends.Ets.destroy_all(project)
  end

  def delete_indexes(project, backend) do
    backend.destroy(project)
  end

  def default_create(_project) do
    {:ok, []}
  end

  def default_update(_project, _entities) do
    {:ok, [], []}
  end

  defp start_supervised_store(%Project{} = project, create_fn, update_fn, backend) do
    start_supervised!(Dispatch)
    start_supervised!(Backends.Ets)
    start_supervised!({Store, [project, create_fn, update_fn, backend]})
    assert_eventually alive?(), 1500
    Store.enable()
    assert_eventually ready?(project), 1500
  end

  def with_a_started_store(%{project: project, backend: backend}) do
    start_supervised_store(project, &default_create/1, &default_update/2, backend)

    :ok
  end

  describe "starting" do
    test "the create function is called if there are no disk files", %{
      project: project,
      backend: backend
    } do
      me = self()

      create_fn = fn ^project ->
        send(me, :create)
        {:ok, []}
      end

      update_fn = fn _, _ ->
        send(me, :update)
        {:ok, [], []}
      end

      start_supervised_store(project, create_fn, update_fn, backend)

      assert_receive :create
      refute_receive :update
    end

    test "the start function receives stale if there is a disk file", %{
      project: project,
      backend: backend
    } do
      me = self()

      create_fn = fn ^project -> {:ok, [reference()]} end

      update_fn = fn _, _ ->
        send(me, :update)
        {:ok, [], []}
      end

      start_supervised_store(project, create_fn, update_fn, backend)

      restart_store(project)

      assert_receive :update
    end

    test "starts empty if there are no disk files", %{project: project, backend: backend} do
      start_supervised_store(project, &default_create/1, &default_update/2, backend)

      assert [] = all_entries(backend)

      entry = definition()
      Store.replace([entry])
      assert all_entries(backend) == [entry]
    end

    test "incorporates any indexed files in an empty index", %{project: project, backend: backend} do
      create = fn _ ->
        entries = [
          reference(path: "/foo/bar/baz.ex"),
          reference(path: "/foo/bar/quux.ex")
        ]

        {:ok, entries}
      end

      start_supervised_store(project, create, &default_update/2, backend)

      restart_store(project)

      paths = Enum.map(all_entries(backend), & &1.path)

      assert "/foo/bar/baz.ex" in paths
      assert "/foo/bar/quux.ex" in paths
    end

    test "fails if the reindex fails on an empty index", %{project: project, backend: backend} do
      create = fn _ -> {:error, :broken} end
      start_supervised_store(project, create, &default_update/2, backend)

      assert_eventually ready?(project)

      assert all_entries(backend) == []
    end

    test "incorporates any indexed files in a stale index", %{project: project, backend: backend} do
      create = fn
        _ ->
          {:ok,
           [
             reference(id: 1, path: "/foo/bar/baz.ex"),
             reference(id: 2, path: "/foo/bar/quux.ex")
           ]}
      end

      update = fn _, _ ->
        entries = [
          reference(id: 3, path: "/foo/bar/baz.ex"),
          reference(id: 4, path: "/foo/bar/other.ex")
        ]

        {:ok, entries, []}
      end

      start_supervised_store(project, create, update, backend)

      restart_store(project)

      entries = Enum.map(all_entries(backend), &{&1.id, &1.path})
      assert {2, "/foo/bar/quux.ex"} in entries
      assert {3, "/foo/bar/baz.ex"} in entries
      assert {4, "/foo/bar/other.ex"} in entries
    end

    test "fails if the reinder fails on an stale index", %{project: project, backend: backend} do
      create = fn _ -> {:ok, []} end
      update = fn _, _ -> {:error, :bad} end

      start_supervised_store(project, create, update, backend)
      restart_store(project)

      assert [] = all_entries(backend)
    end

    test "the updater allows you to delete paths", %{project: project, backend: backend} do
      kept_structure = %{root: %{3 => %{4 => %{}}}}

      create = fn _ ->
        entries = [
          structure(path: "/path/to/keep.ex", structure: kept_structure),
          definition(path: "/path/to/keep.ex"),
          structure(path: "/path/to/delete.ex"),
          definition(path: "/path/to/delete.ex"),
          definition(path: "/path/to/delete.ex"),
          structure(path: "/another/path/to/delete.ex"),
          definition(path: "/another/path/to/delete.ex")
        ]

        {:ok, entries}
      end

      update = fn _, _ ->
        {:ok, [], ["/path/to/delete.ex", "/another/path/to/delete.ex"]}
      end

      start_supervised_store(project, create, update, backend)

      restart_store(project)

      assert [entry] = all_entries(backend)
      assert entry.path == "/path/to/keep.ex"

      assert :error = Backends.Ets.structure_for_path("/path/to/delete.ex")
      assert :error = Backends.Ets.structure_for_path("/another/path/to/delete.ex")
      assert {:ok, ^kept_structure} = Backends.Ets.structure_for_path("/path/to/keep.ex")
    end
  end

  describe "replace/1" do
    setup [:with_a_started_store]

    test "replace survives a restart", %{project: project, backend: backend} do
      entries = [definition(subject: My.Module)]

      assert :ok = Store.replace(entries)

      restart_store(project)

      assert_eventually entries == all_entries(backend)
    end
  end

  describe "updating entries in a file" do
    setup [:with_a_started_store]

    test "updates survive a restart", %{project: project, backend: backend} do
      path = "/path/to/something.ex"
      Store.replace([definition(id: 1, subject: My.Module, path: path)])

      Store.update(path, [
        reference(id: 2, subject: Present, path: path)
      ])

      restart_store(project)

      assert_eventually [%{id: 2}] = all_entries(backend)
    end
  end

  def restart_store(%Project{} = project) do
    ref =
      Store
      |> Process.whereis()
      |> Process.monitor()

    Store.stop()

    receive do
      {:DOWN, ^ref, _, _, _} ->
        assert_eventually Store |> Process.whereis() |> is_pid()
        Store.enable()
        assert_eventually ready?(project), 1500
    after
      1000 ->
        raise "Could not stop store"
    end
  end

  def alive? do
    case Process.whereis(Store) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  def ready?(%Project{} = project) do
    alive?() and registered?(project) and Store.loaded?()
  end

  def registered?(%Project{} = project) do
    case :global.whereis_name({:ets_search, Project.name(project)}) do
      :undefined ->
        false

      _pid ->
        true
    end
  end
end
