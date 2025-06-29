defmodule Engine.Search.Store.Backends.Ets.SchemaTest do
  alias Engine.Search.Store.Backends.Ets.Schema
  alias Engine.Search.Store.Backends.Ets.Wal
  alias Forge.Project

  import Forge.Test.Fixtures
  import Wal, only: :macros

  use ExUnit.Case

  setup do
    project = project()

    destroy_index_path(project)

    on_exit(fn ->
      destroy_index_path(project)
    end)

    {:ok, project: project}
  end

  defmodule First do
    use Schema, version: 1
    def to_rows(_), do: []
  end

  defmodule IncrementValue do
    use Schema, version: 2

    def migrate(entries) do
      entries = Enum.map(entries, fn {k, v} -> {k, v + 1} end)
      {:ok, entries}
    end

    def to_rows(_), do: []
  end

  defmodule IncrementKey do
    use Schema, version: 3

    def migrate(entries) do
      {:ok, Enum.map(entries, fn {k, v} -> {k + 1, v} end)}
    end

    def to_rows(_), do: []
  end

  test "it ensures the uniqueness of versions in the schema order", %{project: project} do
    defmodule SameVersion do
      use Schema, version: 1

      def to_rows(_), do: []
    end

    assert_raise ArgumentError, fn -> Schema.load(project, [First, SameVersion]) end
  end

  test "it loads an empty index", %{project: project} do
    assert {:ok, _table_name, _wal, :empty} = Schema.load(project, [First])
  end

  test "it loads existing entries", %{project: project} do
    entries = [
      {{:ref, 1}, :first},
      {{:ref, 2}, :second}
    ]

    write_entries(project, First, entries)
    assert {:ok, _wal, table_name, :stale} = Schema.load(project(), [First])
    assert table_contents(table_name) == entries
  end

  test "allow you to migrate entries", %{project: project} do
    entries = [{1, 1}, {2, 2}, {3, 3}]

    write_entries(project, First, entries)
    assert {:ok, _wal, table_name, :stale} = Schema.load(project, [First, IncrementValue])

    assert table_contents(table_name) == [{1, 2}, {2, 3}, {3, 4}]
  end

  test "removes old wal after migration", %{project: project} do
    write_entries(project, First, [])
    assert Wal.exists?(project, First.version())

    assert {:ok, _table_name, _wal, :empty} = Schema.load(project, [First, IncrementValue])

    refute Wal.exists?(project, First.version())
  end

  test "migrations that already exist on disk will be reapplied", %{project: project} do
    entries = [{1, 1}, {2, 2}, {3, 3}]
    write_entries(project, First, entries)
    write_entries(project, IncrementValue, entries)

    assert {:ok, _wal, table_name, :stale} = Schema.load(project, [First, IncrementValue])

    new_contents = table_contents(table_name)

    assert {1, 2} in new_contents
    assert {2, 3} in new_contents
    assert {3, 4} in new_contents
    assert length(new_contents) == 3

    refute Wal.exists?(project, First.version())
    assert Wal.exists?(project, IncrementValue.version())
  end

  test "migrations will be reapplied", %{project: project} do
    entries = [{1, 1}, {2, 2}, {3, 3}]
    write_entries(project, First, entries)
    write_entries(project, IncrementValue, entries)

    assert {:ok, wal, table_name, :stale} =
             Schema.load(project, [First, IncrementValue, IncrementKey])

    new_contents = table_contents(table_name)

    assert {2, 2} in new_contents
    assert {3, 3} in new_contents
    assert {4, 4} in new_contents
    assert length(new_contents) == 3

    assert Wal.exists?(wal)
    refute Wal.exists?(project, First.version())
    refute Wal.exists?(project, IncrementValue.version())
  end

  test "migrations can delete all entries", %{project: project} do
    defmodule Blank do
      use Schema, version: 2

      def migrate(_) do
        {:ok, []}
      end

      def to_rows(_), do: []
    end

    entries = [{1, 1}, {2, 2}, {3, 3}]
    write_entries(project, First, entries)

    assert {:ok, _wal, table_name, :empty} = Schema.load(project, [First, Blank])
    assert table_contents(table_name) == []
  end

  test "failed migrations fail load", %{project: project} do
    defmodule FailedMigration do
      use Schema, version: 2

      def migrate(_) do
        {:error, :migration_failed}
      end

      def to_rows(_), do: []
    end

    entries = [{1, 1}]
    write_entries(project, First, entries)
    assert {:error, :migration_failed} = Schema.load(project, [First, FailedMigration])
  end

  def destroy_index_path(%Project{} = project) do
    project |> Wal.root_path() |> File.rm_rf()
  end

  def write_entries(project, schema_module, entries) do
    table_name = schema_module.table_name()
    :ets.new(table_name, schema_module.table_options())
    {:ok, wal} = Wal.load(project, schema_module.version(), table_name)

    with_wal wal do
      :ets.insert(table_name, entries)
    end

    Wal.checkpoint(wal)
    :ok = Wal.close(wal)
    :ets.delete(table_name)
  end

  defp table_contents(table) do
    table
    |> :ets.tab2list()
    |> Enum.sort()
  end
end
