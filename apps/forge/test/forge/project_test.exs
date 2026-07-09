defmodule Forge.ProjectTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  use Patch

  import Forge.Test.Fixtures

  alias Forge.Document
  alias Forge.Project

  defp test_project do
    root = Forge.Document.Path.to_uri(__DIR__)
    Project.new(root)
  end

  defp make_document(path) do
    %Document{
      uri: Document.Path.to_uri(path),
      path: path,
      version: 1,
      lines: nil
    }
  end

  defp setup_nested_projects(_context) do
    root_path = Path.join(fixtures_path(), "nested_projects")
    subproject_path = Path.join(root_path, "subproject")

    root_project =
      root_path
      |> Document.Path.to_uri()
      |> Project.new()

    subproject =
      subproject_path
      |> Document.Path.to_uri()
      |> Project.new()

    %{
      root_path: root_path,
      subproject_path: subproject_path,
      root_project: root_project,
      subproject: subproject
    }
  end

  describe "project_for_uri/2" do
    setup :setup_nested_projects

    test "returns the closest project when file is in a nested subproject", %{
      root_project: root_project,
      subproject: subproject,
      subproject_path: subproject_path
    } do
      projects = [root_project, subproject]
      file_uri = Document.Path.to_uri(Path.join(subproject_path, "lib/subproject.ex"))

      result = Project.project_for_uri(projects, file_uri)

      assert result.root_uri == subproject.root_uri
    end

    test "returns the closest project regardless of list order", %{
      root_project: root_project,
      subproject: subproject,
      subproject_path: subproject_path
    } do
      # Test with subproject first in list
      projects = [subproject, root_project]
      file_uri = Document.Path.to_uri(Path.join(subproject_path, "lib/subproject.ex"))

      result = Project.project_for_uri(projects, file_uri)

      assert result.root_uri == subproject.root_uri
    end

    test "returns the root project when file is outside subproject", %{
      root_project: root_project,
      subproject: subproject,
      root_path: root_path
    } do
      projects = [root_project, subproject]
      file_uri = Document.Path.to_uri(Path.join(root_path, "lib/nested_projects.ex"))

      result = Project.project_for_uri(projects, file_uri)

      assert result.root_uri == root_project.root_uri
    end

    test "returns nil when no projects contain the file", %{
      root_project: root_project,
      subproject: subproject
    } do
      projects = [root_project, subproject]
      file_uri = Document.Path.to_uri("/some/other/path/file.ex")

      result = Project.project_for_uri(projects, file_uri)

      assert result == nil
    end

    test "returns nil when projects list is empty" do
      file_uri = Document.Path.to_uri("/some/path/file.ex")

      result = Project.project_for_uri([], file_uri)

      assert result == nil
    end
  end

  describe "project_for_document/2" do
    setup :setup_nested_projects

    test "returns the closest project when document is in a nested subproject", %{
      root_project: root_project,
      subproject: subproject,
      subproject_path: subproject_path
    } do
      projects = [root_project, subproject]
      document = make_document(Path.join(subproject_path, "lib/subproject.ex"))

      result = Project.project_for_document(projects, document)

      assert result.root_uri == subproject.root_uri
    end

    test "returns the closest project regardless of list order", %{
      root_project: root_project,
      subproject: subproject,
      subproject_path: subproject_path
    } do
      # Test with subproject first in list
      projects = [subproject, root_project]
      document = make_document(Path.join(subproject_path, "lib/subproject.ex"))

      result = Project.project_for_document(projects, document)

      assert result.root_uri == subproject.root_uri
    end

    test "returns the root project when document is outside subproject", %{
      root_project: root_project,
      subproject: subproject,
      root_path: root_path
    } do
      projects = [root_project, subproject]
      document = make_document(Path.join(root_path, "lib/nested_projects.ex"))

      result = Project.project_for_document(projects, document)

      assert result.root_uri == root_project.root_uri
    end

    test "returns nil when no projects contain the document", %{
      root_project: root_project,
      subproject: subproject
    } do
      projects = [root_project, subproject]
      document = make_document("/some/other/path/file.ex")

      result = Project.project_for_document(projects, document)

      assert result == nil
    end

    test "returns nil when projects list is empty" do
      document = make_document("/some/path/file.ex")

      result = Project.project_for_document([], document)

      assert result == nil
    end
  end

  describe "name/1" do
    test "returns the folder name unchanged" do
      patch(Project, :folder_name, "my-project.org")
      assert Project.name(test_project()) == "my-project.org"
    end

    test "preserves special characters" do
      patch(Project, :folder_name, "foo.bar")
      assert Project.name(test_project()) == "foo.bar"
    end

    test "preserves capital letters" do
      patch(Project, :folder_name, "FooBar")
      assert Project.name(test_project()) == "FooBar"
    end

    test "preserves leading numbers" do
      patch(Project, :folder_name, "3bar")
      assert Project.name(test_project()) == "3bar"
    end
  end

  describe "ensure_workspace/1" do
    @tag :tmp_dir
    test "creates .gitignore when the workspace directory already exists", %{tmp_dir: tmp_dir} do
      project = tmp_dir |> Document.Path.to_uri() |> Project.new()
      workspace_path = Project.workspace_path(project)
      gitignore_path = Project.workspace_path(project, ".gitignore")

      File.mkdir_p!(workspace_path)

      assert :ok = Project.ensure_workspace(project)
      assert File.regular?(gitignore_path)
    end
  end
end
