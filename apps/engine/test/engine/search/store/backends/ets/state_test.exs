defmodule Engine.Search.Store.Backends.Ets.StateTest do
  use ExUnit.Case, async: true

  import Engine.Search.Store.Backends.Ets.Schemas.V4, only: [by_id: 1]
  import Engine.Test.Entry.Builder

  alias Engine.Search.Store.Backends.Ets.Schema
  alias Engine.Search.Store.Backends.Ets.Schemas.V4
  alias Engine.Search.Store.Backends.Ets.State

  describe "resilience to stale index references" do
    setup do
      table = :ets.new(:stale_ref_test, [:ordered_set])
      state = %State{table_name: table}

      {:ok, state: state}
    end

    test "find_by_subject skips entries whose id key was deleted", %{state: state} do
      entry1 = definition(id: 1, subject: Foo.Bar)
      entry2 = definition(id: 2, subject: Foo.Bar)

      rows = Schema.entries_to_rows([entry1, entry2], V4)
      :ets.insert(state.table_name, rows)

      :ets.delete(state.table_name, by_id(id: 2, type: :module, subtype: :definition))

      results = State.find_by_subject(state, "Foo.Bar", :module, :definition)

      assert [entry] = results
      assert entry.id == 1
    end

    test "find_by_prefix skips entries whose id key was deleted", %{state: state} do
      entry1 = definition(id: 1, subject: Foo.Bar)
      entry2 = definition(id: 2, subject: Foo.Baz)

      rows = Schema.entries_to_rows([entry1, entry2], V4)
      :ets.insert(state.table_name, rows)

      :ets.delete(state.table_name, by_id(id: 2, type: :module, subtype: :definition))

      results = State.find_by_prefix(state, "Foo", :module, :definition)

      assert [entry] = results
      assert entry.id == 1
    end
  end
end
