defmodule Expert.Search.Store.Backends.SqliteTest do
  use ExUnit.Case, async: false

  import Forge.Test.Fixtures

  alias Expert.Search.Store.Backends.Sqlite
  alias Forge.Search.Indexer.Entry

  setup do
    project = project()
    runtime_versions = %{erlang: "engine-erlang", elixir: "engine-elixir"}

    Sqlite.destroy_all(project)
    on_exit(fn -> Sqlite.destroy_all(project) end)

    {:ok, project: project, runtime_versions: runtime_versions}
  end

  describe "prepare/1" do
    test "creates an index for wildcard subject searches constrained by type and subtype", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      database_path = Sqlite.database_path(project, runtime_versions)

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)

      {:ok, conn} = Exqlite.Basic.open(database_path)

      result =
        Exqlite.Basic.exec(
          conn,
          """
          EXPLAIN QUERY PLAN
          SELECT entry_blobs.entry
          FROM entries
          JOIN entry_blobs ON entry_blobs.entry_rowid = entries.rowid
          WHERE type = ? AND subtype = ?
          """,
          [{:blob, :erlang.term_to_binary(:module)}, "definition"]
        )

      assert {:ok, rows, _columns} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)

      assert Enum.any?(rows, fn row ->
               plan = row |> List.last() |> to_string()

               String.contains?(plan, "entries_type_subtype_idx") and
                 String.contains?(plan, "type=?") and
                 String.contains?(plan, "subtype=?")
             end)
    end

    test "stores full entry blobs outside the entries metadata table", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      database_path = Sqlite.database_path(project, runtime_versions)

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)

      {:ok, conn} = Exqlite.Basic.open(database_path)

      result = Exqlite.Basic.exec(conn, "PRAGMA table_info(entries)")
      assert {:ok, entry_columns, _columns} = Exqlite.Basic.rows(result)

      result = Exqlite.Basic.exec(conn, "PRAGMA table_info(entry_blobs)")
      assert {:ok, blob_columns, _columns} = Exqlite.Basic.rows(result)

      assert :ok = Exqlite.Basic.close(conn)

      refute Enum.any?(entry_columns, fn [_cid, name | _] -> name == "entry" end)
      assert Enum.any?(blob_columns, fn [_cid, name | _] -> name == "entry" end)
    end

    test "recreates a database with a different schema version", %{
      project: project,
      runtime_versions: runtime_versions
    } do
      database_path = Sqlite.database_path(project, runtime_versions)

      File.mkdir_p!(Path.dirname(database_path))
      {:ok, conn} = Exqlite.Basic.open(database_path)

      result =
        Exqlite.Basic.exec(conn, """
        CREATE TABLE schema (
          id INTEGER PRIMARY KEY,
          version INTEGER NOT NULL,
          inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        """)

      assert {:ok, [], []} = Exqlite.Basic.rows(result)

      result = Exqlite.Basic.exec(conn, "INSERT INTO schema (version) VALUES (?)", [999])
      assert {:ok, [], []} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert Path.basename(database_path) == "source.index.sqlite3"

      {:ok, conn} = Exqlite.Basic.open(database_path)
      result = Exqlite.Basic.exec(conn, "SELECT version FROM schema")
      assert {:ok, [[1]], ["version"]} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)
    end
  end

  describe "replace_all/2" do
    test "persists entries", %{project: project, runtime_versions: runtime_versions} do
      entry = %Entry{
        id: 1,
        subject: Persisted.Module,
        path: "/persisted.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, [entry])
      assert :ok = stop_supervised!(:sqlite)

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :stale} = Sqlite.prepare(pid)
      assert [^entry] = Sqlite.find_by_subject(project, Persisted.Module, :_, :_)
    end
  end

  describe "insert/2" do
    test "persists entries", %{project: project, runtime_versions: runtime_versions} do
      entry = %Entry{
        id: 1,
        subject: Incremental.Module,
        path: "/incremental.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.insert(project, [entry])
      assert :ok = stop_supervised!(:sqlite)

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :stale} = Sqlite.prepare(pid)
      assert [^entry] = Sqlite.find_by_subject(project, Incremental.Module, :_, :_)
    end
  end

  describe "apply_index_update/3" do
    test "replaces entries by path", %{project: project, runtime_versions: runtime_versions} do
      old_entry = %Entry{
        id: 1,
        subject: Replaced.Old,
        path: "/same.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      new_entry = %Entry{
        id: 2,
        subject: Replaced.New,
        path: "/same.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)

      assert {:ok, []} = Sqlite.apply_index_update(project, [old_entry], [])
      assert {:ok, [1]} = Sqlite.apply_index_update(project, [new_entry], [])

      assert [] = Sqlite.find_by_subject(project, Replaced.Old, :_, :_)
      assert [^new_entry] = Sqlite.find_by_subject(project, Replaced.New, :_, :_)

      database_path = Sqlite.database_path(project, runtime_versions)
      {:ok, conn} = Exqlite.Basic.open(database_path)

      result =
        Exqlite.Basic.exec(conn, """
        SELECT (SELECT COUNT(*) FROM entries), (SELECT COUNT(*) FROM entry_blobs)
        """)

      assert {:ok, [[1, 1]], _columns} = Exqlite.Basic.rows(result)
      assert :ok = Exqlite.Basic.close(conn)
    end
  end

  describe "parent/2" do
    test "returns the containing entry", %{project: project, runtime_versions: runtime_versions} do
      path = "/blocks.ex"

      parent = %Entry{
        id: 1,
        subject: Parent,
        path: path,
        type: :module,
        subtype: :definition,
        block_id: 1
      }

      child = %Entry{
        id: 2,
        subject: Parent.Child,
        path: path,
        type: :module,
        subtype: :definition,
        block_id: 2
      }

      structure = Entry.block_structure(path, %{1 => %{2 => %{}}})

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, [parent, child, structure])

      assert {:ok, ^parent} = Sqlite.parent(project, child)
    end
  end

  describe "structure_for_path/2" do
    test "returns the block structure", %{project: project, runtime_versions: runtime_versions} do
      path = "/blocks.ex"
      structure = Entry.block_structure(path, %{1 => %{2 => %{}}})

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, [structure])

      assert {:ok, %{1 => %{2 => %{}}}} = Sqlite.structure_for_path(project, path)
    end
  end

  describe "find_by_ids/4" do
    test "preserves input order", %{project: project, runtime_versions: runtime_versions} do
      one = %Entry{
        id: 1,
        subject: One,
        path: "/file.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      two = %Entry{
        id: 2,
        subject: Two,
        path: "/file.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      three = %Entry{
        id: 3,
        subject: Three,
        path: "/file.ex",
        type: :module,
        subtype: :definition,
        block_id: :root
      }

      pid =
        start_supervised!(%{
          id: :sqlite,
          start: {Sqlite, :start_link, [project, [runtime_versions: runtime_versions]]}
        })

      assert {:ok, :empty} = Sqlite.prepare(pid)
      assert :ok = Sqlite.replace_all(project, [one, two, three])

      assert [^three, ^one, ^three] = Sqlite.find_by_ids(project, [3, 1, 3], :_, :definition)
    end
  end
end
