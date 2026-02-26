defmodule Forge.ProjectUmbrellaTest do
  alias Forge.Document
  alias Forge.Project
  alias Forge.Workspace

  use ExUnit.Case, async: true

  import Forge.Test.Fixtures

  defp umbrella_root, do: Path.join(fixtures_path(), "umbrella")
  defp sub_app_path(name), do: Path.join([umbrella_root(), "apps", name])
  defp package_project_path(name), do: Path.join([umbrella_root(), "packages", name])

  setup do
    Workspace.set_workspace(nil)

    on_exit(fn ->
      Workspace.set_workspace(nil)
    end)

    :ok
  end

  describe "umbrella_apps_path/1" do
    test "returns apps_path for an umbrella project" do
      assert Project.umbrella_apps_path(umbrella_root()) == "apps"
    end

    test "returns nil for a sub-app directory" do
      assert Project.umbrella_apps_path(sub_app_path("first")) == nil
    end

    test "returns nil for a directory without mix.exs" do
      assert Project.umbrella_apps_path(Path.join(fixtures_path(), "nonexistent")) == nil
    end

    test "returns nil for a non-umbrella project" do
      project_path = Path.join(fixtures_path(), "project")

      if File.exists?(Path.join(project_path, "mix.exs")) do
        assert Project.umbrella_apps_path(project_path) == nil
      end
    end
  end

  describe "find_parent_root_dir/1 with umbrella projects" do
    test "returns umbrella root URI for a file inside a sub-app" do
      file_uri = Document.Path.to_uri(Path.join(sub_app_path("first"), "lib/first.ex"))
      result = Project.find_parent_root_dir(file_uri)

      expected = Document.Path.to_uri(umbrella_root())
      assert result == expected
    end

    test "returns umbrella root URI for a file in sub-app with same name as umbrella" do
      file_uri = Document.Path.to_uri(Path.join(sub_app_path("umbrella"), "lib/umbrella.ex"))
      result = Project.find_parent_root_dir(file_uri)

      expected = Document.Path.to_uri(umbrella_root())
      assert result == expected
    end

    test "returns umbrella root URI for sub-app mix.exs" do
      file_uri = Document.Path.to_uri(Path.join(sub_app_path("second"), "mix.exs"))
      result = Project.find_parent_root_dir(file_uri)

      expected = Document.Path.to_uri(umbrella_root())
      assert result == expected
    end

    test "returns non-umbrella package root URI for a file outside apps_path" do
      file_uri = Document.Path.to_uri(Path.join(package_project_path("search"), "lib/search.ex"))
      result = Project.find_parent_root_dir(file_uri)

      expected = Document.Path.to_uri(package_project_path("search"))
      assert result == expected
    end

    test "returns normal project root for non-umbrella projects" do
      project_path = Path.join(fixtures_path(), "project")

      if File.exists?(Path.join(project_path, "mix.exs")) do
        file_uri = Document.Path.to_uri(Path.join(project_path, "lib/project.ex"))
        result = Project.find_parent_root_dir(file_uri)

        expected = Document.Path.to_uri(project_path)
        assert result == expected
      end
    end

    test "does not traverse above workspace root while detecting umbrella root" do
      Workspace.set_workspace(Workspace.new(sub_app_path("first")))

      file_uri = Document.Path.to_uri(Path.join(sub_app_path("first"), "lib/first.ex"))
      result = Project.find_parent_root_dir(file_uri)

      expected = Document.Path.to_uri(sub_app_path("first"))
      assert result == expected
    end
  end

  describe "find_project/1 with umbrella projects" do
    test "returns project rooted at umbrella root for sub-app files" do
      file_uri = Document.Path.to_uri(Path.join(sub_app_path("first"), "lib/first.ex"))
      project = Project.find_project(file_uri)

      expected_root = Document.Path.to_uri(umbrella_root())
      assert project.root_uri == expected_root
    end

    test "returns project rooted at umbrella root for sub-app with same name" do
      file_uri = Document.Path.to_uri(Path.join(sub_app_path("umbrella"), "lib/umbrella.ex"))
      project = Project.find_project(file_uri)

      expected_root = Document.Path.to_uri(umbrella_root())
      assert project.root_uri == expected_root
    end

    test "returns project rooted at a non-umbrella package outside apps_path" do
      file_uri = Document.Path.to_uri(Path.join(package_project_path("search"), "lib/search.ex"))
      project = Project.find_project(file_uri)

      expected_root = Document.Path.to_uri(package_project_path("search"))
      assert project.root_uri == expected_root
    end
  end
end
