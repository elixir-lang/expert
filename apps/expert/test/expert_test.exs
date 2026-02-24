defmodule Expert.ExpertTest do
  alias Expert.State
  alias Forge.Test.Fixtures

  use ExUnit.Case, async: false
  use Patch

  import ExUnit.CaptureLog
  import Expert.Test.Protocol.TransportSupport

  setup do
    :persistent_term.erase(Expert.Configuration)
    with_patched_transport()

    # These tests call `Expert.handle_info/2` directly (bypassing `Expert.Application`),
    # so we must start `Expert.ActiveProjects` to create its ETS tables first.
    start_supervised!({Expert.ActiveProjects, []})

    # window/logMessage comes from Logger via WindowLogHandler,
    # so tests that assert on log notifications must allow :info events through.
    # The :default console handler is suppressed to avoid polluting test output.
    Expert.Logging.WindowLogHandler.attach()
    Logger.configure(level: :info)
    :logger.update_handler_config(:default, :level, :none)

    on_exit(fn ->
      Logger.configure(level: :none)
      :logger.update_handler_config(:default, :level, :all)
    end)

    :ok
  end

  test "sends an error message on engine initialization error" do
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

  test "logs error when Task.Supervisor.start_child fails during initialization" do
    project = Fixtures.project()
    lsp = initialize_lsp(project)

    patch(Expert.ActiveProjects, :projects, [project])
    patch(Task.Supervisor, :start_child, fn _sup, _fun -> {:error, :max_children} end)

    Logger.configure(level: :error)

    log =
      capture_log(fn ->
        assert {:noreply, ^lsp} =
                 Expert.handle_notification(%GenLSP.Notifications.Initialized{}, lsp)
      end)

    Logger.configure(level: :none)

    assert log =~ "Failed to start project initialization for"
    assert log =~ "max_children"
  end

  test "suppresses window/logMessage for emacs client" do
    project = Fixtures.project()
    lsp = initialize_lsp(project, client_name: "Emacs")
    reason = :something_bad

    assert {:noreply, ^lsp} =
             Expert.handle_info({:engine_initialized, project, {:error, reason}}, lsp)

    error_message = "[Project #{project.root_uri}] Failed to initialize: #{inspect(reason)}"
    error_message_type = GenLSP.Enumerations.MessageType.error()

    refute_receive {:transport, %GenLSP.Notifications.WindowLogMessage{}}

    assert_receive {:transport,
                    %GenLSP.Notifications.WindowShowMessage{
                      params: %GenLSP.Structures.ShowMessageParams{
                        type: ^error_message_type,
                        message: ^error_message
                      }
                    }}
  end

  defp initialize_lsp(project, opts \\ []) do
    assigns = start_supervised!(GenLSP.Assigns, id: make_ref())

    {:ok, _response, state} = State.initialize(State.new(), initialize_request(project, opts))
    GenLSP.Assigns.merge(assigns, %{state: state})

    lsp = %GenLSP.LSP{mod: Expert, assigns: assigns}
    # These tests do not boot Expert.Application, so we mirror runtime setup by
    # setting the global LSP reference used by the window logger handler.
    :persistent_term.put(:expert_lsp, lsp)
    lsp
  end

  defp initialize_request(project, opts) do
    root_uri = project.root_uri
    root_path = Forge.Project.root_path(project)
    client_name = opts[:client_name]

    client_info =
      if is_binary(client_name) do
        %{name: client_name, version: "test"}
      end

    %GenLSP.Requests.Initialize{
      id: 1,
      jsonrpc: "2.0",
      method: "initialize",
      params: %GenLSP.Structures.InitializeParams{
        capabilities: %GenLSP.Structures.ClientCapabilities{},
        client_info: client_info,
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
