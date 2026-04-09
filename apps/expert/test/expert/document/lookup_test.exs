defmodule Expert.Document.LookupTest do
  use ExUnit.Case, async: false

  import Forge.Test.Fixtures

  alias Expert.Document.Context
  alias Expert.Document.Lookup
  alias Expert.Project.Store
  alias Forge.Document
  alias Forge.Project
  alias Forge.Workspace

  defp make_document(path) do
    %Document{
      uri: Document.Path.to_uri(path),
      path: path,
      version: 1,
      lines: nil
    }
  end

  setup do
    start_supervised!({Store, []})
    start_supervised!(Document.Store)

    project_root = fixtures_path() |> Path.join("workspace_folders")

    Workspace.set_workspace(Workspace.new(project_root, [project_root]))

    on_exit(fn ->
      Workspace.set_workspace(nil)
    end)

    project_a =
      project_root
      |> Path.join("main")
      |> Document.Path.to_uri()
      |> Project.new()

    project_b =
      project_root
      |> Path.join("secondary")
      |> Document.Path.to_uri()
      |> Project.new()

    Store.set_projects([project_a, project_b])

    [project_a: project_a, project_b: project_b, project_root: project_root]
  end

  defp with_workspace(workspace, fun) do
    previous_workspace = Workspace.get_workspace()
    Workspace.set_workspace(workspace)

    try do
      fun.()
    after
      Workspace.set_workspace(previous_workspace)
    end
  end

  describe "resolve/2 project selection" do
    test "returns the closest project when URI is in a nested subproject" do
      root_path = Path.join(fixtures_path(), "nested_projects")
      subproject_path = Path.join(root_path, "subproject")

      root_project = root_path |> Document.Path.to_uri() |> Project.new()
      subproject = subproject_path |> Document.Path.to_uri() |> Project.new()
      uri = Document.Path.to_uri(Path.join(subproject_path, "lib/subproject.ex"))

      ctx = Lookup.resolve(uri, [root_project, subproject])

      assert %Context{project: %Project{} = project} = ctx
      assert project.root_uri == subproject.root_uri
    end

    test "returns the closest project regardless of list order" do
      root_path = Path.join(fixtures_path(), "nested_projects")
      subproject_path = Path.join(root_path, "subproject")

      root_project = root_path |> Document.Path.to_uri() |> Project.new()
      subproject = subproject_path |> Document.Path.to_uri() |> Project.new()
      uri = Document.Path.to_uri(Path.join(subproject_path, "lib/subproject.ex"))

      ctx = Lookup.resolve(uri, [subproject, root_project])

      assert %Context{project: %Project{} = project} = ctx
      assert project.root_uri == subproject.root_uri
    end

    test "returns the root project when URI is outside subproject" do
      root_path = Path.join(fixtures_path(), "nested_projects")
      subproject_path = Path.join(root_path, "subproject")

      root_project = root_path |> Document.Path.to_uri() |> Project.new()
      subproject = subproject_path |> Document.Path.to_uri() |> Project.new()
      uri = Document.Path.to_uri(Path.join(root_path, "lib/nested_projects.ex"))

      ctx = Lookup.resolve(uri, [root_project, subproject])

      assert %Context{project: %Project{} = project} = ctx
      assert project.root_uri == root_project.root_uri
    end

    test "returns bare context when no projects contain an Elixir URI" do
      uri = Document.Path.to_uri("/some/other/path/file.ex")

      ctx = Lookup.resolve(uri, [])

      assert %Context{kind: :bare, project: nil} = ctx
    end

    test "returns closest project for a document" do
      root_path = Path.join(fixtures_path(), "nested_projects")
      subproject_path = Path.join(root_path, "subproject")

      root_project = root_path |> Document.Path.to_uri() |> Project.new()
      subproject = subproject_path |> Document.Path.to_uri() |> Project.new()
      document = make_document(Path.join(subproject_path, "lib/subproject.ex"))

      ctx = Lookup.resolve(document, [root_project, subproject])

      assert %Context{project: %Project{} = project} = ctx
      assert project.root_uri == subproject.root_uri
    end
  end

  describe "resolve/2 with URI" do
    test "returns :project context when project is active", %{
      project_a: project_a,
      project_root: root
    } do
      Store.transition(project_a, :ready)
      uri = Document.Path.to_uri(Path.join([root, "main", "lib", "main.ex"]))
      projects = Store.projects()

      ctx = Lookup.resolve(uri, projects)

      assert %Context{kind: :project, uri: ^uri, project: %Project{}} = ctx
      assert ctx.project.root_uri == project_a.root_uri
    end

    test "returns :project context when project exists but is pending", %{
      project_a: project_a,
      project_root: root
    } do
      uri = Document.Path.to_uri(Path.join([root, "main", "lib", "main.ex"]))
      projects = Store.projects()

      ctx = Lookup.resolve(uri, projects)

      assert %Context{kind: :project, uri: ^uri, project: %Project{}} = ctx
      assert ctx.project.root_uri == project_a.root_uri
    end

    test "returns :project context when project is blocked", %{
      project_a: project_a,
      project_root: root
    } do
      Store.transition(project_a, :blocked)
      uri = Document.Path.to_uri(Path.join([root, "main", "lib", "main.ex"]))
      projects = Store.projects()

      ctx = Lookup.resolve(uri, projects)

      assert %Context{kind: :project, uri: ^uri, project: %Project{}} = ctx
    end

    test "returns :bare context for .ex file outside any project" do
      uri = "file:///tmp/standalone_script.ex"
      projects = Store.projects()

      ctx = Lookup.resolve(uri, projects)

      assert %Context{kind: :bare, uri: ^uri, project: nil} = ctx
    end

    test "returns :bare context for .exs file outside any project" do
      uri = "file:///tmp/standalone_script.exs"
      projects = Store.projects()

      ctx = Lookup.resolve(uri, projects)

      assert %Context{kind: :bare, uri: ^uri, project: nil} = ctx
    end

    test "returns :bare context for non-elixir file outside any project" do
      uri = "file:///tmp/readme.md"
      projects = Store.projects()

      ctx = Lookup.resolve(uri, projects)

      assert %Context{kind: :bare, uri: ^uri, project: nil} = ctx
    end

    test "populates document from store when available", %{
      project_a: project_a,
      project_root: root
    } do
      Store.transition(project_a, :ready)
      uri = Document.Path.to_uri(Path.join([root, "main", "lib", "main.ex"]))

      Document.Store.open(uri, "defmodule Main do\nend\n", 1, "elixir")
      projects = Store.projects()

      ctx = Lookup.resolve(uri, projects)

      assert %Context{kind: :project, document: %Document{}} = ctx
      assert ctx.document.uri == uri

      Document.Store.close(uri)
    end

    test "document is nil when not in store", %{
      project_a: project_a,
      project_root: root
    } do
      Store.transition(project_a, :ready)
      uri = Document.Path.to_uri(Path.join([root, "main", "lib", "main.ex"]))
      projects = Store.projects()

      ctx = Lookup.resolve(uri, projects)

      assert %Context{kind: :project, document: nil} = ctx
    end
  end

  describe "find_project_root_uri/1" do
    test "returns nil for a document outside any project" do
      assert Lookup.find_project_root_uri("file:///tmp/orphan.ex") == nil
    end

    test "finds umbrella root for a file inside a sub-app" do
      umbrella_root = Path.join(fixtures_path(), "umbrella")

      file_uri =
        Document.Path.to_uri(
          Path.join([umbrella_root, "apps", "first", "lib", "umbrella", "first.ex"])
        )

      with_workspace(Workspace.new(umbrella_root, [umbrella_root]), fn ->
        assert Lookup.find_project_root_uri(file_uri) == Document.Path.to_uri(umbrella_root)
      end)
    end

    test "finds package project outside umbrella apps_path" do
      umbrella_root = Path.join(fixtures_path(), "umbrella")

      file_uri =
        Document.Path.to_uri(Path.join([umbrella_root, "packages", "search", "lib", "search.ex"]))

      with_workspace(Workspace.new(umbrella_root, [umbrella_root]), fn ->
        assert Lookup.find_project_root_uri(file_uri) ==
                 Document.Path.to_uri(Path.join([umbrella_root, "packages", "search"]))
      end)
    end

    test "finds umbrella root when apps_path is custom" do
      umbrella_root = Path.join(fixtures_path(), "umbrella_custom_apps_path")

      file_uri =
        Document.Path.to_uri(Path.join([umbrella_root, "packages", "first", "lib", "first.ex"]))

      with_workspace(Workspace.new(umbrella_root, [umbrella_root]), fn ->
        assert Lookup.find_project_root_uri(file_uri) == Document.Path.to_uri(umbrella_root)
      end)
    end

    test "finds normal project root for non-umbrella projects" do
      project_path = Path.join(fixtures_path(), "project")
      file_uri = Document.Path.to_uri(Path.join([project_path, "lib", "project.ex"]))

      with_workspace(Workspace.new(project_path, [project_path]), fn ->
        assert Lookup.find_project_root_uri(file_uri) == Document.Path.to_uri(project_path)
      end)
    end

    test "does not traverse above workspace root while discovering" do
      umbrella_root = Path.join(fixtures_path(), "umbrella")
      sub_app_path = Path.join([umbrella_root, "apps", "first"])
      file_uri = Document.Path.to_uri(Path.join([sub_app_path, "lib", "umbrella", "first.ex"]))

      with_workspace(Workspace.new(sub_app_path, [sub_app_path]), fn ->
        assert Lookup.find_project_root_uri(file_uri) == Document.Path.to_uri(sub_app_path)
      end)
    end

    test "uses the containing workspace folder as boundary when root_path is nil" do
      project_root = Path.join(fixtures_path(), "workspace_folders")
      main_path = Path.join(project_root, "main")
      secondary_path = Path.join(project_root, "secondary")

      file_uri = Document.Path.to_uri(Path.join([secondary_path, "lib", "secondary.ex"]))

      with_workspace(Workspace.new(nil, [main_path, secondary_path]), fn ->
        assert Lookup.find_project_root_uri(file_uri) == Document.Path.to_uri(secondary_path)
      end)
    end
  end

  describe "resolve/2 with Document" do
    test "returns :project context for document in active project", %{
      project_a: project_a,
      project_root: root
    } do
      Store.transition(project_a, :ready)
      path = Path.join([root, "main", "lib", "main.ex"])
      uri = Document.Path.to_uri(path)

      Document.Store.open(uri, "defmodule Main do\nend\n", 1, "elixir")
      {:ok, document} = Document.Store.fetch(uri)

      projects = Store.projects()
      ctx = Lookup.resolve(document, projects)

      assert %Context{kind: :project, document: %Document{}, project: %Project{}} = ctx
      assert ctx.project.root_uri == project_a.root_uri

      Document.Store.close(uri)
    end

    test "returns :project context for document in pending project", %{
      project_root: root
    } do
      path = Path.join([root, "main", "lib", "main.ex"])
      uri = Document.Path.to_uri(path)

      Document.Store.open(uri, "defmodule Main do\nend\n", 1, "elixir")
      {:ok, document} = Document.Store.fetch(uri)

      projects = Store.projects()
      ctx = Lookup.resolve(document, projects)

      assert %Context{kind: :project} = ctx

      Document.Store.close(uri)
    end

    test "returns :bare context for document not in any project" do
      uri = "file:///tmp/orphan.ex"
      document = %Document{uri: uri, path: "/tmp/orphan.ex"}

      ctx = Lookup.resolve(document, Store.projects())

      assert %Context{kind: :bare, project: nil} = ctx
    end
  end

  describe "resolve_from_request/2" do
    test "resolves from a params struct with text_document.uri", %{
      project_a: project_a,
      project_root: root
    } do
      Store.transition(project_a, :ready)
      uri = Document.Path.to_uri(Path.join([root, "main", "lib", "main.ex"]))

      params = %{text_document: %{uri: uri}}

      ctx = Lookup.resolve_from_request(params, Store.projects())

      assert %Context{uri: ^uri} = ctx
      assert ctx.project.root_uri == project_a.root_uri
    end

    test "returns bare context when no URI can be extracted" do
      params = %{some: :random_struct}

      ctx = Lookup.resolve_from_request(params, Store.projects())

      assert %Context{kind: :bare, uri: nil} = ctx
    end
  end
end
