defmodule Expert.Search.Store.StateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Forge.Test.Fixtures

  alias Expert.Search.Fuzzy
  alias Expert.Search.Store.State
  alias Forge.Formats
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  defmodule QueryBackend do
    @behaviour Expert.Search.Store.Backend

    def delete_by_path(_project, _path), do: {:ok, []}
    def new(_project), do: {:ok, :new}
    def prepare(_), do: {:ok, :empty}
    def insert(_project, _entries), do: :ok
    def replace_all(_project, _entries), do: :ok

    def apply_index_update(_project, _entries, _paths),
      do: {:ok, []}

    def find_by_subject(_project, :_, :module, :definition), do: [entry(1)]
    def find_by_subject(_project, _subject, _type, _subtype), do: []
    def find_by_prefix(_project, _prefix, _type, _subtype), do: []
    def find_by_ids(_project, [2], :module, :definition), do: [entry(2)]
    def find_by_ids(_project, _ids, _type, _subtype), do: []
    def path_to_ids(_project), do: %{}
    def definitions_for_fuzzy(_project), do: []
    def siblings(_project, _entry), do: []
    def parent(_project, _entry), do: nil
    def structure_for_path(_project, _path), do: {:ok, %{}}
    def drop(_project), do: :ok
    def destroy(_project), do: :ok

    defp entry(id) do
      %Entry{
        id: id,
        subject: QueryBackend.Result,
        path: "/query_backend.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }
    end
  end

  defmodule NotStartedBackend do
    @behaviour Expert.Search.Store.Backend

    def new(_project), do: {:error, :not_started}
    def prepare(_), do: exit(:prepare_should_not_be_called)
    def delete_by_path(_project, _path), do: {:ok, []}
    def insert(_project, _entries), do: :ok
    def replace_all(_project, _entries), do: :ok

    def apply_index_update(_project, _entries, _paths),
      do: {:ok, []}

    def find_by_subject(_project, _subject, _type, _subtype), do: []
    def find_by_prefix(_project, _prefix, _type, _subtype), do: []
    def find_by_ids(_project, _ids, _type, _subtype), do: []
    def path_to_ids(_project), do: %{}
    def definitions_for_fuzzy(_project), do: []
    def siblings(_project, _entry), do: []
    def parent(_project, _entry), do: nil
    def structure_for_path(_project, _path), do: {:ok, %{}}
    def drop(_project), do: :ok
    def destroy(_project), do: :ok
  end

  defmodule TraceBackend do
    @behaviour Expert.Search.Store.Backend

    def new(project), do: {:ok, project}
    def prepare(project), do: {:ok, prepare_status(project)}
    def sync(_project), do: :ok
    def insert(project, entries), do: set_entries(project, entries(project) ++ entries)

    def replace_all(project, entries) do
      record_operation(project, :replace_all)
      set_entries(project, entries)
    end

    def apply_index_update(project, updated_entries, paths_to_clear) do
      record_operation(project, :apply_index_update)

      paths_to_clear = MapSet.new(paths_to_clear)

      {deleted_entries, kept_entries} =
        Enum.split_with(entries(project), &MapSet.member?(paths_to_clear, &1.path))

      set_entries(project, kept_entries ++ updated_entries)

      {:ok, Enum.flat_map(deleted_entries, &List.wrap(&1.id))}
    end

    def delete_by_path(project, path) do
      apply_index_update(project, [], [path])
    end

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

    def set_entries(%Project{} = project, entries) do
      :persistent_term.put({__MODULE__, Project.unique_name(project)}, entries)
      :ok
    end

    def entries(%Project{} = project) do
      :persistent_term.get({__MODULE__, Project.unique_name(project)}, [])
    end

    def reset(%Project{} = project) do
      project_name = Project.unique_name(project)
      :persistent_term.erase({__MODULE__, project_name})
      :persistent_term.erase({__MODULE__, project_name, :prepare_status})
      :persistent_term.erase({__MODULE__, project_name, :operations})
      :ok
    end

    def set_prepare_status(%Project{} = project, status) when status in [:empty, :stale] do
      :persistent_term.put({__MODULE__, Project.unique_name(project), :prepare_status}, status)
    end

    def operations(%Project{} = project) do
      :persistent_term.get({__MODULE__, Project.unique_name(project), :operations}, [])
    end

    def clear_operations(%Project{} = project) do
      :persistent_term.erase({__MODULE__, Project.unique_name(project), :operations})
    end

    defp prepare_status(%Project{} = project) do
      :persistent_term.get({__MODULE__, Project.unique_name(project), :prepare_status}, :stale)
    end

    defp record_operation(%Project{} = project, operation) do
      key = {__MODULE__, Project.unique_name(project), :operations}
      operations = :persistent_term.get(key, [])
      :persistent_term.put(key, operations ++ [operation])
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
    TraceBackend.reset(project())
    :ok
  end

  test "load/1 returns backend startup errors" do
    Logger.put_module_level(State, :error)
    on_exit(fn -> Logger.put_module_level(State, Logger.level()) end)

    state = State.new(project(), NotStartedBackend)

    assert {{:error, :not_started}, log} = with_log(fn -> State.load(state) end)
    assert log =~ "Could not initialize index backend"
  end

  test "all queries backend entries and fuzzy uses in-memory ids" do
    project = project()

    fuzzy_entry = %Entry{
      id: 2,
      subject: QueryBackend.FuzzyNeedle,
      path: "/query_backend.ex",
      type: :module,
      subtype: :definition,
      block_id: :root
    }

    state = %State{
      State.new(project, QueryBackend)
      | loaded?: true,
        fuzzy: Fuzzy.from_entries(project, [fuzzy_entry])
    }

    assert {:ok, [%Entry{id: 1}]} = State.all(state, type: :module, subtype: :definition)

    assert {:ok, [%Entry{id: 2}]} =
             State.fuzzy(state, "Needle", type: :module, subtype: :definition)
  end

  test "commit_traces replaces traced paths and removes old exact module definitions" do
    project = project()
    old_path = "/old_trace.ex"
    trace_path = "/new_trace.ex"
    module = TraceCommit.Sample

    old_entries = [
      definition(id: 1, path: old_path, subject: module, type: :module),
      definition(id: 2, path: old_path, subject: Formats.mfa(module, :value, 0)),
      definition(id: 3, path: "/kept.ex", subject: TraceCommit.Kept, type: :module)
    ]

    new_entry = definition(id: 4, path: trace_path, subject: module, type: :module)

    TraceBackend.set_entries(project, old_entries)

    state = %State{
      State.new(project, TraceBackend)
      | loaded?: true,
        load_status: :ready,
        fuzzy: Fuzzy.from_entries(project, old_entries)
    }

    assert {:ok, _state} = State.commit_traces(state, [{trace_path, [module], [new_entry]}])

    entries = TraceBackend.entries(project)

    refute Enum.any?(entries, &(&1.subject == Formats.mfa(module, :value, 0)))
    assert Enum.any?(entries, &(&1.path == trace_path and &1.subject == module))
    assert Enum.any?(entries, &(&1.path == old_path and &1.type == :metadata))
    assert Enum.any?(entries, &(&1.subject == TraceCommit.Kept))
  end

  test "commit_traces makes an unloaded store queryable" do
    project = project()
    path = "/trace_reference.ex"
    subject = Formats.mfa(TraceCommit.Queryable, :value, 0)
    entry = reference(id: 1, path: path, subject: subject)

    TraceBackend.set_entries(project, [])
    state = State.new(project, TraceBackend)

    assert {:ok, state} = State.commit_traces(state, [{path, [TraceCommit.Queryable], [entry]}])

    assert {:ok, [^entry]} =
             State.exact(state, subject, type: {:function, :usage}, subtype: :reference)
  end

  test "commit_traces bulk replaces an empty backend" do
    project = project()
    path = "/empty_trace_commit.ex"
    entry = definition(id: 1, path: path, subject: TraceCommit.EmptyBulk, type: :module)

    TraceBackend.set_prepare_status(project, :empty)
    TraceBackend.set_entries(project, [])
    TraceBackend.clear_operations(project)

    state = State.new(project, TraceBackend)

    assert {:ok, state} = State.commit_traces(state, [{path, [TraceCommit.EmptyBulk], [entry]}])

    assert state.loaded?
    assert state.load_status == :ready
    assert [:replace_all] = TraceBackend.operations(project)
    assert Enum.any?(TraceBackend.entries(project), &(&1.subject == TraceCommit.EmptyBulk))
  end

  defp definition(opts) do
    %Entry{
      id: Keyword.fetch!(opts, :id),
      path: Keyword.fetch!(opts, :path),
      subject: Keyword.fetch!(opts, :subject),
      type: Keyword.get(opts, :type, {:function, :public}),
      subtype: :definition,
      block_id: :root
    }
  end

  defp reference(opts) do
    %Entry{
      id: Keyword.fetch!(opts, :id),
      path: Keyword.fetch!(opts, :path),
      subject: Keyword.fetch!(opts, :subject),
      type: Keyword.get(opts, :type, {:function, :usage}),
      subtype: :reference,
      block_id: :root
    }
  end
end
