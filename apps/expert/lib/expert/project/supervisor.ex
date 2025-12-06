defmodule Expert.Project.Supervisor do
  alias Expert.EngineSupervisor
  alias Expert.Project.Diagnostics
  alias Expert.Project.Intelligence
  alias Expert.Project.Node
  alias Expert.Project.SearchListener
  alias Forge.Project

  # TODO: this module is slightly weird
  # it is a module based supervisor, but has lots of dynamic supervisor functions
  # what I learned is that in Expert.Application, it is starting an ad hoc
  # dynamic supervisor, calling a function from this module
  # Later, when the server is initializing, it calls the start function in
  # this module, which starts a normal supervisor, which the start_link and
  # init callbacks will be called
  # my suggestion is to separate the dynamic supervisor functionalities from
  # this module into its own module

  use Supervisor

  def start_link(%Project{} = project) do
    Supervisor.start_link(__MODULE__, project, name: name(project))
  end

  def init(%Project{} = project) do
    children = [
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
