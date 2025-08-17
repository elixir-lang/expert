defmodule Expert.EngineNodeTest do
  alias Expert.EngineNode
  alias Expert.EngineSupervisor

  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  use ExUnit.Case, async: false

  setup do
    project = project()
    start_supervised!({EngineSupervisor, project})
    {:ok, %{project: project}}
  end

  test "it should be able to stop a project node and won't restart", %{project: project} do
    {:ok, _node_name, _} = EngineNode.start(project)

    project_alive? = project |> EngineNode.name() |> Process.whereis() |> Process.alive?()

    assert project_alive?
    assert :ok = EngineNode.stop(project, 1500)
    assert_eventually Process.whereis(EngineNode.name(project)) == nil, :timer.seconds(5)
  end

  test "it should be stopped atomically when the startup process is dead", %{project: project} do
    test_pid = self()

    linked_node_process =
      spawn(fn ->
        {:ok, _node_name, _} = EngineNode.start(project)
        send(test_pid, :started)
      end)

    assert_receive :started, 1500

    node_process_name = EngineNode.name(project)

    assert node_process_name |> Process.whereis() |> Process.alive?()
    Process.exit(linked_node_process, :kill)
    assert_eventually Process.whereis(node_process_name) == nil, 50
  end
end
