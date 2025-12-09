defmodule Expert.ExpertTest do
  alias Forge.Test.Fixtures

  use ExUnit.Case, async: false
  use Patch
  use Forge.Test.EventualAssertions

  require GenLSP.Test

  import Expert.Test.Protocol.TransportSupport

  defp start_expert do
    patch(System, :argv, fn -> ["--port", "0"] end)

    assert {:ok, _} = Application.ensure_all_started(:expert)

    on_exit(fn -> Application.stop(:expert) end)
  end

  describe "server testing" do
    setup do
      start_expert()

      %{lsp: lsp} = :sys.get_state(Expert.Buffer)
      {:ok, port} = :inet.port(GenLSP.Buffer.comm_state(Expert.Buffer).lsocket)

      expert = %{
        lsp: lsp,
        port: port
      }

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
  end
end
