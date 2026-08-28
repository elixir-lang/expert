defmodule Expert.Project.IndexerTest do
  use ExUnit.Case, async: false
  use Patch
  use Expert.Test.DispatchFake

  import Forge.EngineApi.Messages
  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Expert.EngineApi
  alias Expert.Project.Indexer
  alias Expert.Project.Node, as: ProjectNode
  alias Expert.Search.Store
  alias Expert.Search.Store.Backends.Sqlite
  alias Expert.Test.DispatchFake
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  # The first assertion after a broadcast waits on `Search.Store.enable/1`, which the store
  # allows 30 seconds for. Setup destroys the database first, so a cold rebuild can outlast the
  # global `assert_receive_timeout` of one second.
  @enable_timeout :timer.seconds(5)

  setup do
    project = project()
    DispatchFake.start()
    Sqlite.destroy_all(project)

    start_supervised!({Sqlite, [project, runtime_versions: runtime_versions()]})
    start_supervised!({Store, [project, Sqlite]})

    task_supervisor = :"#{Project.unique_name(project)}::indexer_test_task_supervisor"
    start_supervised!({Task.Supervisor, name: task_supervisor})

    EngineApi.register_listener(project, self(), [project_index_ready()])

    on_exit(fn -> Sqlite.destroy_all(project) end)

    {:ok, project: project, task_supervisor: task_supervisor}
  end

  describe "initial project compile" do
    test "forces compilation when the persisted index is empty", %{
      project: project,
      task_supervisor: task_supervisor
    } do
      test_pid = self()

      patch(Store, :load_status, fn ^project -> :empty end)

      patch(ProjectNode, :trigger_build, fn ^project, force? ->
        send(test_pid, {:trigger_build, force?})
      end)

      start_supervised!(
        {Indexer, [project, task_supervisor: task_supervisor, initial_compile?: true]}
      )

      assert_receive {:trigger_build, true}
    end

    test "uses a normal compilation when a persisted index exists", %{
      project: project,
      task_supervisor: task_supervisor
    } do
      test_pid = self()

      patch(Store, :load_status, fn ^project -> :stale end)

      patch(ProjectNode, :trigger_build, fn ^project, force? ->
        send(test_pid, {:trigger_build, force?})
      end)

      start_supervised!(
        {Indexer, [project, task_supervisor: task_supervisor, initial_compile?: true]}
      )

      assert_receive {:trigger_build, false}
    end
  end

  test "creates the initial index after a successful project compile", %{
    project: project,
    task_supervisor: task_supervisor
  } do
    test_pid = self()
    entry = definition(id: 1, subject: ProjectIndexer.Initial, path: "/initial.ex")

    patch(EngineApi, :call, fn ^project, Engine.Compilation.TraceBuffer, :drain_definitions, [] ->
      {:ok, %{}}
    end)

    start_supervised!(
      {Indexer,
       [
         project,
         task_supervisor: task_supervisor,
         create_index: fn ^project ->
           send(test_pid, :create_index)

           {:ok, [entry],
            fn ->
              send(test_pid, {:after_apply, Store.exact(project, ProjectIndexer.Initial, [])})
              :ok
            end}
         end,
         update_index: fn ^project, _path_to_ids ->
           send(test_pid, :update_index)
           {:ok, [], [], fn -> :ok end}
         end
       ]}
    )

    EngineApi.broadcast(project, project_compiled(project: project, status: :success))

    assert_receive :create_index, @enable_timeout
    refute_receive :update_index

    assert_receive {:after_apply, {:ok, [^entry]}}
    assert_receive project_index_ready(project: ^project)
    assert_eventually {:ok, [^entry]} = Store.exact(project, ProjectIndexer.Initial, [])
  end

  test "creates the initial index even when the project compile reports an error", %{
    project: project,
    task_supervisor: task_supervisor
  } do
    test_pid = self()
    entry = definition(id: 1, subject: ProjectIndexer.OnError, path: "/on_error.ex")

    start_supervised!(
      {Indexer,
       [
         project,
         task_supervisor: task_supervisor,
         create_index: fn ^project ->
           send(test_pid, :create_index)

           {:ok, [entry],
            fn ->
              send(test_pid, {:after_apply, Store.exact(project, ProjectIndexer.OnError, [])})
              :ok
            end}
         end,
         update_index: fn ^project, _path_to_ids ->
           send(test_pid, :update_index)
           {:ok, [], [], fn -> :ok end}
         end
       ]}
    )

    EngineApi.broadcast(project, project_compiled(project: project, status: :error))

    assert_receive :create_index, @enable_timeout
    assert_receive {:after_apply, {:ok, [^entry]}}
    assert_receive project_index_ready(project: ^project)
    assert_eventually {:ok, [^entry]} = Store.exact(project, ProjectIndexer.OnError, [])
  end

  test "updates an existing index after later successful project compiles", %{
    project: project,
    task_supervisor: task_supervisor
  } do
    path = "/stale.ex"
    old_entry = definition(id: 1, subject: ProjectIndexer.Stale, path: path)
    new_entry = definition(id: 2, subject: ProjectIndexer.Fresh, path: path)
    assert :ok = Store.replace(project, [old_entry])

    test_pid = self()

    patch(EngineApi, :call, fn ^project, Engine.Compilation.TraceBuffer, :drain_definitions, [] ->
      {:ok, %{}}
    end)

    start_supervised!(
      {Indexer,
       [
         project,
         task_supervisor: task_supervisor,
         create_index: fn ^project ->
           send(test_pid, :create_index)
           {:ok, []}
         end,
         update_index: fn ^project, path_to_ids ->
           send(test_pid, {:update_index, path_to_ids})

           {:ok, [new_entry], [],
            fn ->
              send(test_pid, {:after_apply, Store.exact(project, ProjectIndexer.Fresh, [])})
              :ok
            end}
         end
       ]}
    )

    EngineApi.broadcast(project, project_compiled(project: project, status: :success))

    assert_receive {:update_index, %{^path => 1}}, @enable_timeout
    refute_receive :create_index

    assert_receive {:after_apply, {:ok, [^new_entry]}}
    assert_receive project_index_ready(project: ^project)
    assert {:ok, []} = Store.exact(project, ProjectIndexer.Stale, [])
    assert {:ok, [^new_entry]} = Store.exact(project, ProjectIndexer.Fresh, [])
  end

  test "applies compiler trace definitions after the normal index write", %{
    project: project,
    task_supervisor: task_supervisor
  } do
    test_pid = self()
    structure_entry = Entry.block_structure("/generated.ex", %{root: %{}})
    source_entry = definition(id: 1, subject: ProjectIndexer.Source, path: "/generated.ex")
    trace_entry = definition(id: 2, subject: ProjectIndexer.Generated, path: "/generated.ex")

    patch(EngineApi, :call, fn ^project, Engine.Compilation.TraceBuffer, :drain_definitions, [] ->
      {:ok, %{trace_entry.path => [trace_entry]}}
    end)

    start_supervised!(
      {Indexer,
       [
         project,
         task_supervisor: task_supervisor,
         create_index: fn ^project ->
           send(test_pid, {:create_started, self()})

           receive do
             :finish_index -> {:ok, [structure_entry, source_entry], fn -> :ok end}
           end
         end,
         update_index: fn ^project, _path_to_ids -> {:ok, [], [], fn -> :ok end} end
       ]}
    )

    EngineApi.broadcast(project, project_compiled(project: project, status: :success))
    assert_receive {:create_started, index_task}
    refute_receive project_index_ready(project: ^project), 100

    send(index_task, :finish_index)

    assert_receive project_index_ready(project: ^project)

    assert {:ok, [%Entry{subject: ProjectIndexer.Generated}]} =
             Store.exact(project, ProjectIndexer.Generated, [])

    assert {:ok, [^source_entry]} = Store.exact(project, ProjectIndexer.Source, [])
  end

  test "uses the latest trace batch when successful compiles overlap indexing", %{
    project: project,
    task_supervisor: task_supervisor
  } do
    test_pid = self()
    first_entry = definition(id: 1, subject: ProjectIndexer.First, path: "/stale_trace.ex")
    second_entry = definition(id: 2, subject: ProjectIndexer.Second, path: "/stale_trace.ex")
    old_trace = definition(id: 3, subject: ProjectIndexer.OldTrace, path: "/stale_trace.ex")
    new_trace = definition(id: 4, subject: ProjectIndexer.NewTrace, path: "/stale_trace.ex")

    patch(EngineApi, :call, fn ^project, Engine.Compilation.TraceBuffer, :drain_definitions, [] ->
      send(test_pid, {:drain_trace, self()})

      receive do
        {:trace_batch, batch} -> {:ok, batch}
      end
    end)

    start_supervised!(
      {Indexer,
       [
         project,
         task_supervisor: task_supervisor,
         create_index: fn ^project ->
           send(test_pid, {:index_started, self(), :first})

           receive do
             :finish_index -> {:ok, [first_entry], fn -> :ok end}
           end
         end,
         update_index: fn ^project, _path_to_ids ->
           send(test_pid, {:index_started, self(), :second})

           receive do
             :finish_index -> {:ok, [second_entry], [], fn -> :ok end}
           end
         end
       ]}
    )

    EngineApi.broadcast(project, project_compiled(project: project, status: :success))
    assert_receive {:drain_trace, drain_task}
    send(drain_task, {:trace_batch, %{old_trace.path => [old_trace]}})
    assert_receive {:index_started, first_task, :first}

    EngineApi.broadcast(project, project_compiled(project: project, status: :success))
    assert_receive {:drain_trace, drain_task}
    send(drain_task, {:trace_batch, %{new_trace.path => [new_trace]}})

    send(first_task, :finish_index)
    assert_receive {:index_started, second_task, :second}

    send(second_task, :finish_index)
    assert_receive project_index_ready(project: ^project)

    assert {:ok, []} = Store.exact(project, ProjectIndexer.OldTrace, [])
    assert {:ok, []} = Store.exact(project, ProjectIndexer.First, [])

    assert {:ok, [%Entry{subject: ProjectIndexer.NewTrace}]} =
             Store.exact(project, ProjectIndexer.NewTrace, [])

    assert {:ok, [%Entry{subject: ProjectIndexer.Second}]} =
             Store.exact(project, ProjectIndexer.Second, [])
  end

  test "source entries win over duplicate compiler trace definitions", %{
    project: project,
    task_supervisor: task_supervisor
  } do
    path = "/duplicate.ex"
    source_entry = definition(id: 1, subject: ProjectIndexer.Duplicate, path: path)
    trace_entry = definition(id: 2, subject: ProjectIndexer.Duplicate, path: path)
    unique_trace_entry = definition(id: 3, subject: ProjectIndexer.TraceOnly, path: path)
    duplicate_trace_entry = definition(id: 4, subject: ProjectIndexer.TraceOnly, path: path)

    patch(EngineApi, :call, fn ^project, Engine.Compilation.TraceBuffer, :drain_definitions, [] ->
      {:ok, %{path => [trace_entry, unique_trace_entry, duplicate_trace_entry]}}
    end)

    start_supervised!(
      {Indexer,
       [
         project,
         task_supervisor: task_supervisor,
         create_index: fn ^project -> {:ok, [source_entry], fn -> :ok end} end,
         update_index: fn ^project, _path_to_ids -> {:ok, [], [], fn -> :ok end} end
       ]}
    )

    EngineApi.broadcast(project, project_compiled(project: project, status: :success))

    assert_receive project_index_ready(project: ^project)
    assert {:ok, [^source_entry]} = Store.exact(project, ProjectIndexer.Duplicate, [])

    assert {:ok, [%Entry{subject: ProjectIndexer.TraceOnly}]} =
             Store.exact(project, ProjectIndexer.TraceOnly, [])
  end

  test "compiler trace definitions replace stale use definitions", %{
    project: project,
    task_supervisor: task_supervisor
  } do
    path = "/use_definition.ex"

    stale_entry =
      [id: 1, subject: ProjectIndexer.Injected, path: path]
      |> definition()
      |> Entry.put_metadata(%{via: :use, original_mfa: "OldProvider.injected/0"})

    compiler_entry =
      [id: 2, subject: ProjectIndexer.Injected, path: path]
      |> definition()
      |> Entry.put_metadata(%{via: :use, original_mfa: "ActualProvider.injected/0"})

    impossible_entry =
      [id: 3, subject: ProjectIndexer.DisabledInjection, path: path]
      |> definition()
      |> Entry.put_metadata(%{via: :use, original_mfa: "Provider.disabled/0"})

    patch(EngineApi, :call, fn ^project, Engine.Compilation.TraceBuffer, :drain_definitions, [] ->
      {:ok, %{path => [compiler_entry]}}
    end)

    start_supervised!(
      {Indexer,
       [
         project,
         task_supervisor: task_supervisor,
         create_index: fn ^project ->
           {:ok, [stale_entry, impossible_entry], fn -> :ok end}
         end,
         update_index: fn ^project, _path_to_ids -> {:ok, [], [], fn -> :ok end} end
       ]}
    )

    EngineApi.broadcast(project, project_compiled(project: project, status: :success))

    assert_receive project_index_ready(project: ^project)

    assert {:ok, [%Entry{metadata: %{original_mfa: "ActualProvider.injected/0"}}]} =
             Store.exact(project, ProjectIndexer.Injected, [])

    assert {:ok, []} = Store.exact(project, ProjectIndexer.DisabledInjection, [])
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

  defp runtime_versions, do: %{erlang: "engine-erlang", elixir: "engine-elixir"}
end
