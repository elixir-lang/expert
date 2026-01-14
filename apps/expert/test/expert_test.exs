defmodule Expert.ExpertTest do
  alias Expert.State
  alias Forge.Test.Fixtures

  use ExUnit.Case, async: false
  use Patch

  import Expert.Test.Protocol.TransportSupport

  setup do
    :persistent_term.erase(Expert.Configuration)
    :ok
  end

  test "sends an error message on engine initialization error" do
    with_patched_transport()

    project = Fixtures.project()
    lsp = initialize_lsp(project)

    reason = :something_bad

    assert {:noreply, ^lsp} =
             Expert.handle_info({:engine_initialized, project, {:error, reason}}, lsp)

    error_message = "[Project #{project.root_uri}] Failed to initialize: #{inspect(reason)}"
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

  defp initialize_lsp(project) do
    assigns = start_supervised!(GenLSP.Assigns, id: make_ref())

    {:ok, _response, state} = State.initialize(State.new(), initialize_request(project))
    GenLSP.Assigns.merge(assigns, %{state: state})

    %GenLSP.LSP{mod: Expert, assigns: assigns}
  end

  defp initialize_request(project) do
    root_uri = project.root_uri
    root_path = Forge.Project.root_path(project)

    %GenLSP.Requests.Initialize{
      id: 1,
      jsonrpc: "2.0",
      method: "initialize",
      params: %GenLSP.Structures.InitializeParams{
        capabilities: %GenLSP.Structures.ClientCapabilities{},
        process_id: "",
        root_uri: root_uri,
        root_path: root_path,
        workspace_folders: [
          %GenLSP.Structures.WorkspaceFolder{
            name: root_path,
            uri: root_uri
          }
        ]
      }
    }
  end
end
