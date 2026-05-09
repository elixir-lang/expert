defmodule Expert.ExpertTest do
  use ExUnit.Case, async: false
  use Patch

  import Expert.Test.Protocol.TransportSupport
  import ExUnit.CaptureLog

  alias Expert.State
  alias Forge.Project
  alias Forge.Test.Fixtures
  alias GenLSP.Notifications.WorkspaceDidChangeConfiguration
  alias GenLSP.Structures.DidChangeConfigurationParams

  setup do
    :persistent_term.erase(Expert.Configuration)
    Forge.Workspace.set_workspace(nil)
    with_patched_transport()

    # These tests call `Expert.handle_info/2` directly (bypassing `Expert.Application`),
    # so we must start the stores that runtime boot normally provides.
    start_supervised!({Forge.Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    start_supervised!({Expert.Project.Store, []})

    # window/logMessage comes from Logger via WindowLogHandler,
    # so tests that assert on log notifications must allow :info events through.
    # The :default console handler is suppressed to avoid polluting test output.
    Expert.Logging.WindowLogHandler.attach()
    Logger.configure(level: :info)
    :logger.update_handler_config(:default, :level, :none)

    on_exit(fn ->
      Forge.Workspace.set_workspace(nil)
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

    error_message = "[#{Project.name(project)}] Failed to initialize: #{inspect(reason)}"
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

  describe "engine build failure messages" do
    test "include captured build output" do
      project = Fixtures.project()
      lsp = initialize_lsp(project)

      output = """
      ** (Mix.Error) httpc request failed with: {:failed_connect, ...}.

      Could not install Rebar because Mix could not download metadata at https://builds.hex.pm/installs/rebar.csv.

          (mix  1.17.3) lib/mix.ex:647: Mix.raise/2
          .../priv/build_engine.exs:31: (file)\
      """

      reason =
        {:shutdown,
         {:failed_to_start_child, {Expert.Project.Node, "demo::1"},
          {:error, "Build script exited with status: 1", output}}}

      assert {:noreply, ^lsp} =
               Expert.handle_info({:engine_initialized, project, {:error, reason}}, lsp)

      assert_receive {:transport,
                      %GenLSP.Notifications.WindowShowMessage{
                        params: %GenLSP.Structures.ShowMessageParams{message: message}
                      }}

      assert message =~ "Engine build failed for demo::1"
      assert message =~ "Build script exited with status: 1"
      # The actual error must be visible to the user, not just the script frame.
      assert message =~ "** (Mix.Error) httpc request failed with"
      assert message =~ "Could not install Rebar because Mix could not download metadata"
    end

    test "omit the details block when captured output is empty" do
      project = Fixtures.project()
      lsp = initialize_lsp(project)

      reason =
        {:shutdown,
         {:failed_to_start_child, {Expert.Project.Node, "demo::1"},
          {:error, "Build script exited with status: 1", ""}}}

      assert {:noreply, ^lsp} =
               Expert.handle_info({:engine_initialized, project, {:error, reason}}, lsp)

      assert_receive {:transport,
                      %GenLSP.Notifications.WindowShowMessage{
                        params: %GenLSP.Structures.ShowMessageParams{message: message}
                      }}

      assert message =~ "Engine build failed for demo::1"
      assert message =~ "Build script exited with status: 1"
      # No trailing newlines / empty section when there is nothing to show.
      refute String.ends_with?(message, "\n\n")
    end
  end

  test "logs error when Task.Supervisor.start_child fails during initialization" do
    project = Fixtures.project()
    lsp = initialize_lsp(project)

    patch(Expert.Project.Store, :projects, [project])
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

    error_message = "[#{Project.name(project)}] Failed to initialize: #{inspect(reason)}"
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

  test "accepts didChangeConfiguration notifications with null settings" do
    project = Fixtures.project()

    {:ok, _response, state} = State.initialize(State.new(), initialize_request(project, []))

    notification = %WorkspaceDidChangeConfiguration{
      params: %DidChangeConfigurationParams{settings: nil}
    }

    assert {:ok, ^state} = State.apply(state, notification)

    config = Expert.Configuration.get()
    assert config.log_level == :info
    assert config.workspace_symbols.min_query_length == 2
  end

  test "initialization stores an empty workspace when root_uri and workspace_folders are nil" do
    request = %GenLSP.Requests.Initialize{
      id: 1,
      jsonrpc: "2.0",
      method: "initialize",
      params: %GenLSP.Structures.InitializeParams{
        capabilities: %GenLSP.Structures.ClientCapabilities{},
        client_info: nil,
        process_id: "",
        root_uri: nil,
        root_path: nil,
        workspace_folders: nil
      }
    }

    assert {:ok, _response, _state} = State.initialize(State.new(), request)

    assert %Forge.Workspace{workspace_folders: []} =
             Forge.Workspace.get_workspace()
  end

  test "document requests return an error when the document cannot be loaded" do
    project = Fixtures.project()
    lsp = initialize_lsp(project)

    Expert.Project.Store.add_projects([project])
    Expert.Project.Store.transition(project, :ready)

    request = %GenLSP.Requests.TextDocumentHover{
      id: 1,
      jsonrpc: "2.0",
      method: "textDocument/hover",
      params: %GenLSP.Structures.HoverParams{
        text_document: %GenLSP.Structures.TextDocumentIdentifier{
          uri:
            project
            |> Forge.Project.root_path()
            |> Path.join("lib/not_open.ex")
            |> Forge.Document.Path.to_uri()
        },
        position: %GenLSP.Structures.Position{line: 0, character: 0}
      }
    }

    assert {
             :reply,
             %GenLSP.ErrorResponse{
               code: code,
               message: "Document could not be loaded"
             },
             ^lsp
           } = Expert.handle_request(request, lsp)

    assert code == GenLSP.Enumerations.ErrorCodes.invalid_request()
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
