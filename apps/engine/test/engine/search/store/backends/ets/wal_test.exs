defmodule Engine.Search.Store.Backends.Ets.WalTest do
  alias Engine.Dispatch
  alias Engine.Search.Store.Backends.Ets.Wal

  import Forge.Test.Fixtures

  use ExUnit.Case
  use Patch

  import Wal, only: :macros

  @table_name :wal_test
  @schema_version 1

  setup do
    project = project()
    new_table()

    patch(Dispatch, :erpc_call, fn Expert.Progress, :begin, [_title, _opts] ->
      {:ok, System.unique_integer([:positive])}
    end)

    patch(Dispatch, :erpc_cast, fn Expert.Progress, _function, _args -> true end)

    on_exit(fn ->
      Wal.destroy(project, @schema_version)
    end)

    {:ok, project: project}
  end

  describe "with_wal/1" do
    test "returns the wal state and the ets operation", %{project: project} do
      {:ok, wal_state} = Wal.load(project, @schema_version, @table_name)

      {:ok, new_state, result} =
        with_wal wal_state do
          :ets.insert(@table_name, {:first, 1})
          :worked
        end

      assert result == :worked
      assert %Wal{} = new_state
    end
  end

  describe "non-write operations are ignored" do
    setup [:with_a_loaded_wal]

    test "ignores lookups", %{wal: wal_state} do
      {:ok, new_wal, _} =
        with_wal wal_state do
          :ets.lookup(@table_name, :first)
        end

      assert {:ok, 0} = Wal.size(new_wal)
    end
  end

  describe "operations" do
    setup [:with_a_loaded_wal]

    test "the wal captures deletes operations", %{wal: wal_state, project: project} do
      with_wal wal_state do
        :ets.insert(@table_name, [{:first, {1, 1}}, {:second, {2, 2}}])
        :ets.delete(@table_name, :second)
      end

      entries = dump_and_close_table()

      assert {:ok, _new_wal, ^entries} = load_from_project(project)
    end

    test "the wal captures delete_all_items operations", %{wal: wal_state, project: project} do
      with_wal wal_state do
        :ets.insert(@table_name, [{:first, 1}, {:second, 2}])
        :ets.delete_all_objects(@table_name)
      end

      dump_and_close_table()
      assert {:ok, _new_wal, []} = load_from_project(project)
    end

    test "the wal captures delete_object operations calls", %{wal: wal_state, project: project} do
      with_wal wal_state do
        :ets.insert(@table_name, [{:first, 1}, {:second, 2}])
        :ets.delete_object(@table_name, {:first, 1})
      end

      entries = dump_and_close_table()
      assert {:ok, _new_wal, ^entries} = load_from_project(project)
    end

    test "the wal captures inserts operations", %{wal: wal_state, project: project} do
      with_wal wal_state do
        :ets.insert(@table_name, [{:first, {3, 6}}])
      end

      entries = dump_and_close_table()

      assert {:ok, _new_wal, ^entries} = load_from_project(project)
    end

    test "the wal captures insert_new operations", %{wal: wal_state, project: project} do
      with_wal wal_state do
        :ets.insert_new(@table_name, [{:first, 1}, {:second, 2}])
      end

      entries = dump_and_close_table()

      assert {:ok, _new_wal, ^entries} = load_from_project(project)
    end

    test "the wal captures match_delete operations", %{wal: wal_state, project: project} do
      with_wal wal_state do
        :ets.insert(@table_name, [{:first, 1}, {:second, 2}, {:third, 1}])
        :ets.match_delete(@table_name, {:_, 1})
      end

      entries = dump_and_close_table()
      assert {:ok, _new_wal, ^entries} = load_from_project(project)
    end

    test "the wal captures select_delete operations", %{wal: wal_state, project: project} do
      with_wal wal_state do
        :ets.insert(@table_name, [{:first, 1}, {:second, 1}, {:third, 3}])
        :ets.select_delete(@table_name, [{{:_, 1}, [], [true]}])
      end

      entries = dump_and_close_table()

      assert {:ok, _new_wal, ^entries} = load_from_project(project)
    end

    test "the wal captures select_replace operations", %{wal: wal_state, project: project} do
      with_wal wal_state do
        :ets.insert(@table_name, [{:first, 1}, {:second, 2}, {:third, 1}])
        :ets.select_replace(@table_name, [{{:third, :_}, [], [{{:third, 3}}]}])
      end

      entries = dump_and_close_table()
      assert {:ok, _new_wal, ^entries} = load_from_project(project)
    end

    test "the wal captures update_counter operations", %{wal: wal_state, project: project} do
      with_wal wal_state do
        :ets.insert(@table_name, [{:first, 1}, {:second, 2}, {:third, 3}])
        :ets.update_counter(@table_name, :first, {2, 1})
      end

      entries = dump_and_close_table()
      assert {:ok, _new_val, ^entries} = load_from_project(project)
    end

    test "the wal captures update_element operations", %{wal: wal_state, project: project} do
      with_wal wal_state do
        :ets.insert(@table_name, [{:first, 1}, {:second, 2}, {:third, 3}])
        :ets.update_element(@table_name, :first, {2, :oops})
      end

      entries = dump_and_close_table()
      assert {:ok, _new_wal, ^entries} = load_from_project(project)
    end
  end

  describe "checkpoints" do
    setup [:with_a_loaded_wal]

    test "fails if the ets table doesn't exist" do
      {:ok, wal_state} = Wal.load(project(), @schema_version, :does_not_exist)
      assert {:error, :no_table} = Wal.checkpoint(wal_state)
    end

    test "gracefully handles an invalid checkpoint", %{wal: wal_state, project: project} do
      :ok = Patch.expose(Wal, find_latest_checkpoint: 1)

      with_wal wal_state do
        :ets.insert(@table_name, [{:first, 1}])
      end

      assert {:ok, new_wal} = Wal.checkpoint(wal_state)
      {:ok, checkpoint_path} = private(Wal.find_latest_checkpoint(new_wal))
      Wal.close(new_wal)
      # write junk over it
      File.write!(checkpoint_path, "this is not data")

      {:ok, new_wal} = Wal.load(project, @schema_version, @table_name)

      assert Wal.size(new_wal) == {:ok, 0}
      assert new_wal.checkpoint_version == 0
    end

    test "can load a checkpoint", %{wal: wal_state, project: project} do
      with_wal wal_state do
        :ets.insert(@table_name, [{:first, 1}, {:second, 2}])
      end

      assert wal_state.checkpoint_version == 0

      # prior, we had no checkpoint and one item in the update
      # log. Checkpointing clears out the updates log and
      # creates a checkpoint file, which can be restored
      assert {:ok, 1} = Wal.size(wal_state)
      assert {:ok, new_wal} = Wal.checkpoint(wal_state)

      checkpoint_version = new_wal.checkpoint_version

      assert checkpoint_version > 0
      assert {:ok, 0} = Wal.size(new_wal)

      items = dump_and_close_table()
      {:ok, loaded_wal, ^items} = load_from_project(project)
      assert loaded_wal.checkpoint_version == checkpoint_version
    end

    test "can handle lots of data", %{wal: wal_state, project: project} do
      stream =
        1..500_000
        |> Stream.cycle()
        |> Stream.map(fn count -> {{:item, count}, count} end)

      for item <- Enum.take(stream, 20_000) do
        with_wal wal_state do
          :ets.insert(@table_name, item)
        end
      end

      {:ok, new_state} = Wal.checkpoint(wal_state)
      :ok = Wal.close(new_state)
      data = dump_and_close_table()

      assert {:ok, _wal_state, entries} = load_from_project(project)

      assert Enum.sort(entries) == Enum.sort(data)
    end

    test "checkpoints after a certain number of operations", %{project: project} do
      {:ok, wal_state} = Wal.load(project, @schema_version, @table_name, max_wal_operations: 5)

      with_wal wal_state do
        :ets.insert(@table_name, {:first, 1})
        :ets.insert(@table_name, {:first, 2})
        :ets.insert(@table_name, {:first, 3})
        :ets.insert(@table_name, {:first, 4})
      end

      assert Wal.size(wal_state) == {:ok, 4}

      with_wal wal_state do
        :ets.insert(@table_name, {:first, 5})
      end

      assert Wal.size(wal_state) == {:ok, 0}
    end
  end

  defp with_a_loaded_wal(%{project: project}) do
    {:ok, wal_state} = Wal.load(project, @schema_version, @table_name)
    {:ok, wal: wal_state}
  end

  defp dump_and_close_table do
    items = :ets.tab2list(@table_name)
    :ets.delete(@table_name)
    items
  end

  defp load_from_project(project) do
    new_table()
    {:ok, new_wal} = Wal.load(project, @schema_version, @table_name)
    entries = :ets.tab2list(@table_name)
    {:ok, new_wal, entries}
  end

  defp new_table do
    if :ets.info(@table_name) == :undefined do
      :ets.new(@table_name, [:named_table, :ordered_set])
    end
  end
end
