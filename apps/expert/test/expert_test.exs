defmodule Expert.ExpertTest do
  alias Forge.Test.Fixtures

  use ExUnit.Case, async: false
  use Forge.Test.EventualAssertions
  use Patch

  require GenLSP.Test

  import Expert.Test.Protocol.TransportSupport

  describe "server testing" do
    defp buffer_opts do
      [communication: {GenLSP.Communication.TCP, [port: 0]}]
    end

    defp start_application_children do
      pids =
        for child_spec <- Expert.Application.children(buffer: buffer_opts()) do
          start_supervised!(child_spec)
        end

      on_exit(fn ->
        # NOTE: The test hangs for some reason without manually exiting
        for pid <- pids do
          Process.exit(pid, :normal)
        end
      end)
    end

    setup do
      start_application_children()

      comm_state = GenLSP.Buffer.comm_state(Expert.Buffer)

      {:ok, port} = :inet.port(comm_state.lsocket)
      %{lsp: lsp} = :sys.get_state(Expert.Buffer)

      expert = %{lsp: lsp, port: port}
      client = GenLSP.Test.client(expert)

      [expert: expert, client: client]
    end

    test "replies to initialize with expert info and capabilities", %{client: client} do
      id = System.unique_integer([:positive])

      project = Fixtures.project()

      root_uri = project.root_uri
      root_path = Forge.Project.root_path(project)

      assert :ok ==
               GenLSP.Test.request(client, %{
                 "id" => id,
                 "jsonrpc" => "2.0",
                 "method" => "initialize",
                 "params" => %{
                   "rootPath" => root_path,
                   "rootUri" => root_uri,
                   "capabilities" => %{},
                   "workspaceFolders" => [
                     %{
                       uri: root_uri,
                       name: root_path
                     }
                   ]
                 }
               })

      GenLSP.Test.assert_result(^id, result, 500)

      {:ok, initialize_result} =
        GenLSP.Requests.Initialize.result()
        |> Schematic.dump(Expert.State.initialize_result())

      assert result == initialize_result
    end
  end

  test "sends an error message on engine initialization error" do
    with_patched_transport()

    assigns = start_supervised!(GenLSP.Assigns, id: make_ref())
    GenLSP.Assigns.merge(assigns, %{state: %{}})

    lsp = %GenLSP.LSP{mod: Expert, assigns: assigns}

    reason = :something_bad

    assert {:noreply, ^lsp} = Expert.handle_info({:engine_initialized, {:error, reason}}, lsp)

    error_message = "Failed to initialize: #{inspect(reason)}"
    error_message_type = GenLSP.Enumerations.MessageType.error()

    assert_receive {:transport,
                    %GenLSP.Notifications.WindowLogMessage{
                      params: %GenLSP.Structures.LogMessageParams{
                        type: ^error_message_type,
                        message: ^error_message
                      }
                    }}

    assert_receive {:transport,
                    %GenLSP.Notifications.WindowShowMessage{
                      params: %GenLSP.Structures.ShowMessageParams{
                        type: ^error_message_type,
                        message: ^error_message
                      }
                    }}
  end
end
