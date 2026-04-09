defmodule Expert.Project.StoreTest do
  use ExUnit.Case, async: false

  import Forge.Test.Fixtures

  alias Expert.Project.Store
  alias Forge.Document
  alias Forge.Project

  setup do
    start_supervised!({Store, []})

    project_root = fixtures_path() |> Path.join("workspace_folders")

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

    [project_a: project_a, project_b: project_b]
  end

  describe "projects/0" do
    test "returns empty list when no projects are tracked" do
      assert [] = Store.projects()
    end

    test "returns all tracked projects", %{project_a: a, project_b: b} do
      Store.add_projects([a, b])

      projects = Store.projects()
      assert length(projects) == 2
      uris = Enum.map(projects, & &1.root_uri)
      assert a.root_uri in uris
      assert b.root_uri in uris
    end
  end

  describe "find_by_root_uri/1" do
    test "returns nil for unknown URI" do
      assert nil == Store.find_by_root_uri("file:///nonexistent")
    end

    test "returns the project for a known URI", %{project_a: a} do
      Store.add_projects([a])
      found = Store.find_by_root_uri(a.root_uri)
      assert found.root_uri == a.root_uri
    end
  end

  describe "add_projects/1" do
    test "adds projects with :pending status", %{project_a: a} do
      Store.add_projects([a])

      assert [project] = Store.projects()
      assert project.root_uri == a.root_uri
      refute Store.ready?(a)
      refute Store.blocked?(a)
    end

    test "does not overwrite existing projects", %{project_a: a} do
      Store.add_projects([a])
      Store.transition(a, :ready)

      Store.add_projects([a])
      assert Store.ready?(a)
    end
  end

  describe "remove_projects/1" do
    test "removes projects completely", %{project_a: a, project_b: b} do
      Store.add_projects([a, b])
      assert length(Store.projects()) == 2

      Store.remove_projects([a])
      assert [remaining] = Store.projects()
      assert remaining.root_uri == b.root_uri

      refute Store.ready?(a)
      refute Store.blocked?(a)
    end
  end

  describe "set_projects/1" do
    test "clears and repopulates", %{project_a: a, project_b: b} do
      Store.add_projects([a])
      Store.transition(a, :ready)

      Store.set_projects([b])

      assert [project] = Store.projects()
      assert project.root_uri == b.root_uri
      refute Store.ready?(b)
    end
  end

  describe "ready?/1" do
    test "returns false for pending project", %{project_a: a} do
      Store.add_projects([a])
      refute Store.ready?(a)
    end

    test "returns true for ready project", %{project_a: a} do
      Store.add_projects([a])
      Store.transition(a, :ready)
      assert Store.ready?(a)
    end

    test "returns false for blocked project", %{project_a: a} do
      Store.add_projects([a])
      Store.transition(a, :blocked)
      refute Store.ready?(a)
    end

    test "returns false for unknown project", %{project_a: a} do
      refute Store.ready?(a)
    end
  end

  describe "blocked?/1" do
    test "returns false for pending project", %{project_a: a} do
      Store.add_projects([a])
      refute Store.blocked?(a)
    end

    test "returns false for ready project", %{project_a: a} do
      Store.add_projects([a])
      Store.transition(a, :ready)
      refute Store.blocked?(a)
    end

    test "returns true for blocked project", %{project_a: a} do
      Store.add_projects([a])
      Store.transition(a, :blocked)
      assert Store.blocked?(a)
    end

    test "returns false for unknown project", %{project_a: a} do
      refute Store.blocked?(a)
    end
  end

  describe "transition/2" do
    test "changes status", %{project_a: a} do
      Store.add_projects([a])

      assert Store.transition(a, :ready)
      assert Store.ready?(a)
      refute Store.blocked?(a)

      assert Store.transition(a, :blocked)
      refute Store.ready?(a)
      assert Store.blocked?(a)

      assert Store.transition(a, :pending)
      refute Store.ready?(a)
      refute Store.blocked?(a)
    end

    test "returns false for unknown project", %{project_a: a} do
      refute Store.transition(a, :ready)
    end
  end
end
