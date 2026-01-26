defmodule Engine.Search.Store.StateTest do
  alias Engine.Search.Store.State
  alias Forge.Test.Fixtures

  use ExUnit.Case, async: true

  import Fixtures
  import ExUnit.CaptureLog
  require Logger

  defmodule TimeoutBackend do
    @behaviour Engine.Search.Store.Backend

    def delete_by_path(_path) do
      exit({:timeout, {GenServer, :call, [:some_ref]}})
    end

    def new(_project), do: {:ok, :new}
    def prepare(_), do: {:ok, :empty}
    def insert(_entries), do: :ok
    def replace_all(_entries), do: :ok
    def find_by_subject(_subject, _type, _subtype), do: []
    def find_by_prefix(_prefix, _type, _subtype), do: []
    def find_by_ids(_ids, _type, _subtype), do: []
    def reduce(acc, _fun), do: acc
    def siblings(_entry), do: []
    def parent(_entry), do: nil
    def structure_for_path(_path), do: {:ok, %{}}
    def drop, do: :ok
    def destroy(_state), do: :ok
  end

  describe "update_nosync/3" do
    test "catches timeout from backend and logs the warning" do
      Logger.put_module_level(State, :warning)
      on_exit(fn -> Logger.put_module_level(State, Logger.level()) end)

      project = project()

      state =
        State.new(
          project,
          fn _project -> {:ok, []} end,
          fn _project, _backend -> {:ok, [], []} end,
          TimeoutBackend
        )

      {result, log} =
        with_log(fn ->
          State.update_nosync(state, "/some/path.ex", [])
        end)

      assert assert {:ok, returned_state} = result
      assert log =~ "Timeout updating index for path: /some/path.ex"
    end
  end
end
