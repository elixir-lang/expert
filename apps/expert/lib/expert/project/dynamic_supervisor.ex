defmodule Expert.Project.DynamicSupervisor do
  def name do
    Expert.ProjectSupervisor
  end

  def options do
    [name: name(), strategy: :one_for_one]
  end
end
