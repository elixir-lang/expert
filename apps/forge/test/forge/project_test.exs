defmodule Forge.ProjectTest do
  alias Forge.Document
  alias Forge.Project

  use ExUnit.Case, async: false
  use ExUnitProperties
  use Patch

  import Forge.Test.Fixtures

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
    test "a project's name starts with a lowercase character and contains alphanumeric characters and _" do
      check all(folder_name <- string(:ascii, min_length: 1)) do
        patch(Project, :folder_name, folder_name)
        assert Regex.match?(~r/[a-z][a-zA-Z_]*/, Project.name(test_project()))
      end
    end

    test "periods are repleaced with underscores" do
      patch(Project, :folder_name, "foo.bar")
      assert Project.name(test_project()) == "foo_bar"
    end

    test "leading capital letters are downcased" do
      patch(Project, :folder_name, "FooBar")
      assert Project.name(test_project()) == "fooBar"
    end

    test "leading numbers are replaced with p_" do
      patch(Project, :folder_name, "3bar")
      assert Project.name(test_project()) == "p_3bar"
    end
  end
end
