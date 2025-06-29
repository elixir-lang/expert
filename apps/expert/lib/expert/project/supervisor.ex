defmodule Expert.Project.Supervisor do
  alias Expert.Project.Diagnostics
  alias Expert.Project.Intelligence
  alias Expert.Project.Node
  alias Expert.Project.Progress
  alias Expert.Project.SearchListener
  alias Expert.EngineSupervisor
  alias Forge.Project

  use Supervisor

  def start_link(%Project{} = project) do
    Supervisor.start_link(__MODULE__, project, name: name(project))
  end

  def init(%Project{} = project) do
    children = [
      {Progress, project},
      {EngineSupervisor, project},
      {Node, project},
      {Diagnostics, project},
      {Intelligence, project},
      {SearchListener, project}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def start(%Project{} = project) do
    DynamicSupervisor.start_child(Expert.Project.DynamicSupervisor.name(), {__MODULE__, project})
  end

  def stop(%Project{} = project) do
    pid =
      project
      |> name()
      |> Process.whereis()

    DynamicSupervisor.terminate_child(Expert.Project.DynamicSupervisor.name(), pid)
  end

  defp name(%Project{} = project) do
    :"#{Project.name(project)}::supervisor"
  end
end
