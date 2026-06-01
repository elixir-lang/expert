defmodule Expert.Project.NodeStateTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Expert.Project.Node

  test "node down stops the child so rest_for_one restarts listeners" do
    project = project()
    state = %Node.State{project: project, node: :old_node, supervisor_pid: self()}

    patch(File, :rm_rf, fn _path -> {:ok, []} end)

    patch(Expert.EngineNode, :start, fn ^project, _token ->
      send(self(), :node_restarted_in_place)
      {:ok, :new_node, self()}
    end)

    patch(Expert.EngineApi, :schedule_compile, fn ^project, true ->
      send(self(), :compile_scheduled_in_place)
      :ok
    end)

    assert {:stop, :engine_node_down, ^state} = Node.handle_info({:nodedown, :old_node}, state)
    refute_received :node_restarted_in_place
    refute_received :compile_scheduled_in_place
  end
end
