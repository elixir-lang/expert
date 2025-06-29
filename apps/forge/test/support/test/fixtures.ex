defmodule Forge.Test.Fixtures do
  alias Forge.Document
  alias Forge.Project

  use ExUnit.CaseTemplate

  def fixtures_path do
    [__ENV__.file, "..", "..", "..", "fixtures"]
    |> Path.join()
    |> Path.expand()
  end

  def project(project_name) do
    [Path.dirname(__ENV__.file), "..", "..", "fixtures", to_string(project_name)]
    |> Path.join()
    |> Path.expand()
    |> Forge.Document.Path.to_uri()
    |> Project.new()
  end

  def project do
    project(:project)
  end

  def file_path(%Project{} = project, path_relative_to_project) do
    project
    |> Project.project_path()
    |> Path.join(path_relative_to_project)
    |> Path.expand()
  end

  def file_uri(%Project{} = project, relative_path) do
    project
    |> file_path(relative_path)
    |> Document.Path.ensure_uri()
  end
end
