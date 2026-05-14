defmodule Expert.Search.Store.Backends.Ets.WalTest do
  use ExUnit.Case, async: false

  import Expert.Search.Store.Backends.Ets.Wal, only: :macros
  import Forge.Test.Fixtures

  alias Expert.Search.Store.Backends.Ets.Wal

  setup do
    project = project()
    Wal.destroy_all(project)

    on_exit(fn -> Wal.destroy_all(project) end)

    {:ok, project: project, runtime_versions: %{erlang: "engine-erlang", elixir: "engine-elixir"}}
  end

  test "replays persisted ETS operations into the current manager-owned table", %{
    project: project,
    runtime_versions: runtime_versions
  } do
    first_table = :ets.new(:wal_replay_source, [:set])
    old_engine_table = :expert_search_v4
    row = {{:by_id, 1, :module, :definition}, :entry}

    {:ok, wal} = Wal.load(project, 4, first_table, runtime_versions: runtime_versions)

    assert {:ok, wal} =
             Wal.append(wal, [operation(id: 1, function: :insert, args: [old_engine_table, row])])

    :ok = Wal.close(wal)
    :ets.delete(first_table)

    manager_table = :ets.new(:wal_replay_target, [:set])

    assert {:ok, _wal} = Wal.load(project, 4, manager_table, runtime_versions: runtime_versions)
    assert [^row] = :ets.lookup(manager_table, elem(row, 0))
  end
end
