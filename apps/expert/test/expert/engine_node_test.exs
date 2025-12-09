defmodule Expert.EngineNodeTest do
  alias Expert.EngineNode
  alias Expert.EngineSupervisor

  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  use ExUnit.Case, async: false
  use Patch

  setup do
    project = project()
    start_supervised!({Forge.NodePortMapper, []})
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

  test "terminates the server if no elixir is found", %{project: project} do
    test_pid = self()

    patch(Expert.Port, :path_env_at_directory, nil)

    patch(Expert, :terminate, fn _, status ->
      send(test_pid, {:stopped, status})
    end)

    # Note(dorgan): ideally we would use GenLSP.Test here, but
    # calling `server(Expert)` causes the tests to behave erratically
    # and either not run or terminate ExUnit early
    patch(GenLSP, :error, fn _, message ->
      send(test_pid, {:lsp_log, message})
    end)

    {:error, :no_elixir} = EngineNode.start(project)

    assert_receive {:stopped, 1}
    assert_receive {:lsp_log, "Couldn't find an elixir executable for project" <> _}
  end

  test "shuts down with error message if exited with error code", %{project: project} do
    {:ok, _node_name, node_pid} = EngineNode.start(project)

    Process.monitor(node_pid)

    exit_status = 127

    send(node_pid, {nil, {:exit_status, exit_status}})

    assert_receive {:DOWN, _ref, :process, ^node_pid, exit_reason}

    assert {:shutdown, {:node_exit, node_exit}} = exit_reason
    assert %{status: ^exit_status, last_message: last_message} = node_exit
    assert is_binary(last_message)
  end
end
