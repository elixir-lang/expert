defmodule ExpertTest do
  alias Forge.Document
  alias Forge.Project

  import GenLSP.Test
  import Forge.Test.Fixtures

  use ExUnit.Case, async: false
  use Patch

  setup_all do
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    start_supervised!({Task.Supervisor, name: :expert_task_queue})
    start_supervised!({DynamicSupervisor, name: Expert.DynamicSupervisor})
    start_supervised!({DynamicSupervisor, Expert.Project.DynamicSupervisor.options()})

    project_root = fixtures_path() |> Path.join("workspace_folders")

    main_project =
      project_root
      |> Path.join("main")
      |> Document.Path.to_uri()
      |> Project.new()

    secondary_project =
      project_root
      |> Path.join("secondary")
      |> Document.Path.to_uri()
      |> Project.new()

    nested_root_path = fixtures_path() |> Path.join("nested_projects")

    nested_root_project =
      nested_root_path
      |> Document.Path.to_uri()
      |> Project.new()

    nested_subproject =
      nested_root_path
      |> Path.join("subproject")
      |> Document.Path.to_uri()
      |> Project.new()

    [
      project_root: project_root,
      main_project: main_project,
      secondary_project: secondary_project,
      nested_root_path: nested_root_path,
      nested_root_project: nested_root_project,
      nested_subproject: nested_subproject
    ]
  end

  setup do
    # NOTE(doorgan): repeatedly starting and stopping nodes in tests produces some
    # erratic behavior where sometimes some tests won't run. This somewhat mitigates
    # that.
    test_pid = self()

    patch(Expert.Project.Supervisor, :start, fn project ->
      send(test_pid, {:project_alive, project.root_uri})
      {:ok, nil}
    end)

    patch(Expert.Project.Supervisor, :stop, fn project ->
      send(test_pid, {:project_stopped, project.root_uri})
      :ok
    end)

    start_supervised!({Expert.ActiveProjects, []})

    server =
      server(Expert,
        task_supervisor: :expert_task_queue,
        dynamic_supervisor: Expert.DynamicSupervisor
      )

    client = client(server)

    Process.sleep(100)

    [server: server, client: client]
  end

  def initialize_request(root_path, opts \\ []) do
    id = opts[:id] || 1
    projects = Keyword.get(opts, :projects, [])

    workspace_folders =
      if not is_nil(projects) do
        Enum.map(projects, fn project ->
          %{uri: project.root_uri, name: Project.name(project)}
        end)
      end

    %{
      method: "initialize",
      id: id,
      jsonrpc: "2.0",
      params: %{
        rootUri: Document.Path.to_uri(root_path),
        initializationOptions: %{},
        capabilities: %{
          workspace: %{
            workspaceFolders: true
          }
        },
        workspaceFolders: workspace_folders
      }
    }
  end

  def assert_project_alive?(project) do
    expected_uri = project.root_uri
    assert_receive {:project_alive, ^expected_uri}
  end

  def assert_project_stopped?(project) do
    expected_uri = project.root_uri
    assert_receive {:project_stopped, ^expected_uri}
  end

  describe "initialize request" do
    test "starts a project at the initial workspace folders", %{
      client: client,
      project_root: project_root,
      main_project: main_project
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [main_project])
               )

      assert_result(1, %{
        "capabilities" => %{"workspace" => %{"workspaceFolders" => %{"supported" => true}}}
      })

      expected_message = "Started project node for #{Project.name(main_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.ActiveProjects.projects()
      assert project.root_uri == main_project.root_uri

      assert_project_alive?(main_project)
    end
  end

  describe "workspace folders" do
    test "starts project nodes when adding workspace folders", %{
      client: client,
      project_root: project_root,
      main_project: main_project,
      secondary_project: secondary_project
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [main_project])
               )

      assert_result(1, _)

      expected_message = "Started project node for #{Project.name(main_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [_project_1] = Expert.ActiveProjects.projects()

      assert :ok =
               notify(
                 client,
                 %{
                   method: "workspace/didChangeWorkspaceFolders",
                   jsonrpc: "2.0",
                   params: %{
                     event: %{
                       added: [
                         %{uri: secondary_project.root_uri, name: secondary_project.root_uri}
                       ],
                       removed: []
                     }
                   }
                 }
               )

      expected_message = "Started project node for #{Project.name(secondary_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [_, _] = projects = Expert.ActiveProjects.projects()

      for project <- projects do
        assert project.root_uri in [main_project.root_uri, secondary_project.root_uri]
        assert_project_alive?(project)
      end
    end

    test "can remove workspace folders", %{
      client: client,
      project_root: project_root,
      main_project: main_project
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [main_project])
               )

      assert_result(1, _)
      expected_message = "Started project node for #{Project.name(main_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.ActiveProjects.projects()
      assert project.root_uri == main_project.root_uri
      assert_project_alive?(main_project)

      assert :ok =
               notify(
                 client,
                 %{
                   method: "workspace/didChangeWorkspaceFolders",
                   jsonrpc: "2.0",
                   params: %{
                     event: %{
                       added: [],
                       removed: [
                         %{uri: main_project.root_uri, name: main_project.root_uri}
                       ]
                     }
                   }
                 }
               )

      expected_message = "Stopping project node for #{Project.name(main_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [] = Expert.ActiveProjects.projects()
      assert_project_stopped?(main_project)
    end

    test "supports missing workspace_folders in the request", %{
      client: client,
      project_root: project_root
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: nil)
               )

      assert_result(1, %{
        "capabilities" => %{"workspace" => %{"workspaceFolders" => %{"supported" => true}}}
      })

      assert [] = Expert.ActiveProjects.projects()
    end
  end

  describe "opening files" do
    test "starts a project node when opening a file in a folder not specified as workspace folder",
         %{
           client: client,
           project_root: project_root,
           main_project: main_project,
           secondary_project: secondary_project
         } do
      assert :ok =
               request(
                 client,
                 initialize_request(project_root, id: 1, projects: [main_project])
               )

      assert_result(1, _)

      expected_message = "Started project node for #{Project.name(main_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      file_uri = Path.join([secondary_project.root_uri, "lib", "secondary.ex"])

      assert :ok =
               notify(
                 client,
                 %{
                   method: "textDocument/didOpen",
                   jsonrpc: "2.0",
                   params: %{
                     textDocument: %{
                       uri: file_uri,
                       languageId: "elixir",
                       version: 1,
                       text: ""
                     }
                   }
                 }
               )

      expected_message = "Started project node for #{Project.name(secondary_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [_, _] = projects = Expert.ActiveProjects.projects()

      for project <- projects do
        assert project.root_uri in [main_project.root_uri, secondary_project.root_uri]
        assert_project_alive?(project)
      end
    end
  end

  describe "opening files in nested projects" do
    test "starts the subproject node when opening a file in a nested subproject", %{
      client: client,
      nested_root_path: nested_root_path,
      nested_root_project: nested_root_project,
      nested_subproject: nested_subproject
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(nested_root_path, id: 1, projects: [])
               )

      assert_result(1, _)

      file_uri = Path.join([nested_subproject.root_uri, "lib", "subproject.ex"])

      assert :ok =
               notify(
                 client,
                 %{
                   method: "textDocument/didOpen",
                   jsonrpc: "2.0",
                   params: %{
                     textDocument: %{
                       uri: file_uri,
                       languageId: "elixir",
                       version: 1,
                       text: ""
                     }
                   }
                 }
               )

      expected_message = "Started project node for #{Project.name(nested_subproject)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.ActiveProjects.projects()
      assert project.root_uri == nested_subproject.root_uri
      refute project.root_uri == nested_root_project.root_uri

      assert_project_alive?(nested_subproject)
    end

    test "starts the root project node when opening a file outside nested subprojects", %{
      client: client,
      nested_root_path: nested_root_path,
      nested_root_project: nested_root_project
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(nested_root_path, id: 1, projects: [])
               )

      assert_result(1, _)

      file_uri = Path.join([nested_root_project.root_uri, "lib", "nested_projects.ex"])

      assert :ok =
               notify(
                 client,
                 %{
                   method: "textDocument/didOpen",
                   jsonrpc: "2.0",
                   params: %{
                     textDocument: %{
                       uri: file_uri,
                       languageId: "elixir",
                       version: 1,
                       text: ""
                     }
                   }
                 }
               )

      expected_message = "Started project node for #{Project.name(nested_root_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.ActiveProjects.projects()
      assert project.root_uri == nested_root_project.root_uri

      assert_project_alive?(nested_root_project)
    end

    test "uses the subproject when both root and subproject are active", %{
      client: client,
      nested_root_path: nested_root_path,
      nested_root_project: nested_root_project,
      nested_subproject: nested_subproject
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(nested_root_path,
                   id: 1,
                   projects: [nested_root_project, nested_subproject]
                 )
               )

      assert_result(1, _)

      assert length(Expert.ActiveProjects.projects()) == 2

      file_uri = Path.join([nested_subproject.root_uri, "lib", "subproject.ex"])

      assert :ok =
               notify(
                 client,
                 %{
                   method: "textDocument/didOpen",
                   jsonrpc: "2.0",
                   params: %{
                     textDocument: %{
                       uri: file_uri,
                       languageId: "elixir",
                       version: 1,
                       text: ""
                     }
                   }
                 }
               )

      assert length(Expert.ActiveProjects.projects()) == 2
    end

    test "starts subproject when root is already active and file in subproject is opened", %{
      client: client,
      nested_root_path: nested_root_path,
      nested_root_project: nested_root_project,
      nested_subproject: nested_subproject
    } do
      assert :ok =
               request(
                 client,
                 initialize_request(nested_root_path,
                   id: 1,
                   projects: [nested_root_project]
                 )
               )

      assert_result(1, _)

      expected_message = "Started project node for #{Project.name(nested_root_project)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert [project] = Expert.ActiveProjects.projects()
      assert project.root_uri == nested_root_project.root_uri

      file_uri = Path.join([nested_subproject.root_uri, "lib", "subproject.ex"])

      assert :ok =
               notify(
                 client,
                 %{
                   method: "textDocument/didOpen",
                   jsonrpc: "2.0",
                   params: %{
                     textDocument: %{
                       uri: file_uri,
                       languageId: "elixir",
                       version: 1,
                       text: ""
                     }
                   }
                 }
               )

      expected_message = "Started project node for #{Project.name(nested_subproject)}"

      assert_notification(
        "window/logMessage",
        %{"message" => ^expected_message}
      )

      assert length(Expert.ActiveProjects.projects()) == 2

      project_uris = Enum.map(Expert.ActiveProjects.projects(), & &1.root_uri)
      assert nested_root_project.root_uri in project_uris
      assert nested_subproject.root_uri in project_uris

      assert_project_alive?(nested_subproject)
    end
  end
end
