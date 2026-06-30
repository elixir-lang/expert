defmodule Expert.Search.StoreTest do
  use ExUnit.Case, async: false
  use Patch
  use Expert.Test.DispatchFake

  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Expert.Search.Store
  alias Expert.Search.Store.Backends.Sqlite
  alias Expert.Search.Store.State
  alias Expert.Test.DispatchFake
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  defmodule DelayedBackend do
    @behaviour Expert.Search.Store.Backend

    def new(_project), do: {:ok, :new}

    def prepare(_backend) do
      ready? = :persistent_term.get({__MODULE__, :ready?}, false)

      if owner = :persistent_term.get({__MODULE__, :owner}, nil) do
        send(owner, {:prepare, ready?})
      end

      if ready?, do: {:ok, :stale}, else: {:error, :not_ready}
    end

    def sync(_project), do: :ok
    def insert(project, entries), do: set_entries(project, entries(project) ++ entries)
    def replace_all(project, entries), do: set_entries(project, entries)

    def apply_index_update(project, updated_entries, paths_to_clear) do
      paths_to_clear = MapSet.new(paths_to_clear)

      entries =
        project
        |> entries()
        |> Enum.reject(&MapSet.member?(paths_to_clear, &1.path))
        |> Enum.concat(updated_entries)

      :ok = set_entries(project, entries)
      {:ok, []}
    end

    def delete_by_path(project, path), do: apply_index_update(project, [], [path])

    def find_by_subject(project, subject, type, subtype) do
      Enum.filter(entries(project), fn entry ->
        matches?(entry.subject, subject) and matches?(entry.type, type) and
          matches?(entry.subtype, subtype)
      end)
    end

    def find_by_prefix(project, prefix, type, subtype) do
      Enum.filter(entries(project), fn entry ->
        is_binary(entry.subject) and String.starts_with?(entry.subject, prefix) and
          matches?(entry.type, type) and matches?(entry.subtype, subtype)
      end)
    end

    def find_by_ids(_project, _ids, _type, _subtype), do: []
    def path_to_ids(project), do: newest_ids_by_path(entries(project))

    def definitions_for_fuzzy(project),
      do: Enum.filter(entries(project), &(&1.subtype == :definition))

    def siblings(_project, _entry), do: []
    def parent(_project, _entry), do: nil
    def structure_for_path(_project, _path), do: {:ok, %{}}
    def drop(project), do: set_entries(project, [])
    def destroy(project), do: set_entries(project, [])

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)
    def set_ready(ready?), do: :persistent_term.put({__MODULE__, :ready?}, ready?)
    def clear_owner, do: :persistent_term.erase({__MODULE__, :owner})

    def set_entries(%Project{} = project, entries) do
      :persistent_term.put({__MODULE__, Project.unique_name(project)}, entries)
      :ok
    end

    def entries(%Project{} = project) do
      :persistent_term.get({__MODULE__, Project.unique_name(project)}, [])
    end

    defp newest_ids_by_path(entries) do
      Enum.reduce(entries, %{}, fn
        %Entry{path: path, id: id}, ids when is_integer(id) ->
          Map.update(ids, path, id, &max(&1, id))

        _entry, ids ->
          ids
      end)
    end

    defp matches?(_value, :_), do: true
    defp matches?({kind, _}, {kind, :_}), do: true
    defp matches?(value, value), do: true
    defp matches?(_, _), do: false
  end

  setup do
    project = project()
    DispatchFake.start()

    patch(Features, :can_use_compressed_ets_table?, fn ->
      raise "manager storage probed VM features"
    end)

    Sqlite.destroy_all(project)

    start_supervised!({Sqlite, [project, runtime_versions: runtime_versions()]})

    start_supervised!({Store, [project, Sqlite]})

    Store.enable(project)
    assert_eventually(Store.loaded?(project), 1500)

    on_exit(fn -> Sqlite.destroy_all(project) end)

    {:ok, project: project}
  end

  test "replaces and queries entries", %{project: project} do
    entries = [definition(id: 1, subject: Foo.Bar), reference(id: 2, subject: Foo.Bar)]

    assert :ok = Store.replace(project, entries)

    assert {:ok, [entry]} = Store.exact(project, "Foo.Bar", subtype: :definition)
    assert entry.id == 1
  end

  test "updates replace entries for the same path", %{project: project} do
    path = "/path/to/file.ex"

    assert :ok = Store.replace(project, [definition(id: 1, subject: Old.Module, path: path)])
    assert :ok = Store.update(project, path, [definition(id: 2, subject: New.Module, path: path)])
    send(Process.whereis(Store.name(project)), :flush_updates)

    assert_eventually(
      {:ok, [entry]} =
        Store.fuzzy(project, "New", type: :module, subtype: :definition)
    )

    assert entry.id == 2
    assert {:ok, []} = Store.exact(project, Old.Module, subtype: :definition)
  end

  test "flush update errors do not crash the store", %{project: project} do
    store = Process.whereis(Store.name(project))
    test_pid = self()

    patch(State, :flush_buffered_updates, fn _state ->
      send(test_pid, :flush_attempted)
      {:error, :readonly}
    end)

    send(store, :flush_updates)

    assert_receive :flush_attempted
    assert Process.alive?(store)
  end

  test "path_to_ids returns newest indexed id per path", %{project: project} do
    Store.replace(project, [
      definition(id: 1, subject: One, path: "/one.ex"),
      definition(id: 3, subject: Two, path: "/one.ex"),
      definition(id: 2, subject: Three, path: "/two.ex")
    ])

    assert %{"/one.ex" => 3, "/two.ex" => 2} = Store.path_to_ids(project)
  end

  test "destroy resets loaded state instead of corrupting it", %{project: project} do
    assert :ok = Store.replace(project, [definition(id: 1, subject: Destroyed.Module)])
    assert :ok = Store.destroy(project)

    refute Store.loaded?(project)
    assert [] = Store.exact(project, Destroyed.Module, [])

    assert :ok = Store.enable(project)
    assert {:ok, []} = Store.exact(project, Destroyed.Module, [])
  end

  test "writes the persisted index under the supplied engine runtime versions", %{
    project: project
  } do
    assert :ok = Store.replace(project, [definition(id: 1, subject: Engine.Runtime.Versioned)])

    assert File.exists?(Sqlite.database_path(project, runtime_versions()))
  end

  test "commit_traces reports a missing store" do
    missing_project = project(:scratch)

    assert {:error, :not_started} = Store.commit_traces(missing_project, [])
  end

  test "commit_traces makes an empty sqlite store queryable", %{project: project} do
    path = "/trace_commit_sqlite.ex"
    entry = definition(id: 1, path: path, subject: TraceCommit.Sqlite)
    expected_entry = %Entry{entry | path: path |> Path.expand() |> Forge.Path.native()}

    assert :ok = Store.commit_traces(project, [{path, [TraceCommit.Sqlite], [entry]}])

    assert {:ok, [^expected_entry]} =
             Store.exact(project, TraceCommit.Sqlite, type: :module, subtype: :definition)
  end

  test "commit_traces enables public queries after failed initial load" do
    trace_project = project(:scratch)
    path = "/trace_commit.ex"
    entry = definition(id: 1, path: path, subject: TraceCommit.PublicQuery)
    expected_entry = %Entry{entry | path: path |> Path.expand() |> Forge.Path.native()}

    DelayedBackend.set_owner(self())
    DelayedBackend.set_ready(false)
    DelayedBackend.set_entries(trace_project, [])
    on_exit(&DelayedBackend.clear_owner/0)

    start_supervised!({Store, [trace_project, DelayedBackend]})
    assert_receive {:prepare, false}

    DelayedBackend.set_ready(true)

    assert :ok = Store.commit_traces(trace_project, [{path, [TraceCommit.PublicQuery], [entry]}])
    assert_receive {:prepare, true}

    assert {:ok, [^expected_entry]} =
             Store.exact(trace_project, TraceCommit.PublicQuery,
               type: :module,
               subtype: :definition
             )
  end

  defp definition(opts) do
    opts = Keyword.validate!(opts, [:id, :subject, path: "/file.ex"])

    %Entry{
      id: Keyword.fetch!(opts, :id),
      subject: Keyword.fetch!(opts, :subject),
      path: Keyword.fetch!(opts, :path),
      type: :module,
      subtype: :definition,
      block_id: :root
    }
  end

  defp reference(opts) do
    %Entry{definition(opts) | subtype: :reference}
  end

  defp runtime_versions, do: %{erlang: "engine-erlang", elixir: "engine-elixir"}
end
