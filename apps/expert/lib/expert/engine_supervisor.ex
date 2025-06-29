defmodule Expert.EngineSupervisor do
  use DynamicSupervisor

  alias Expert.EngineNode
  alias Forge.Project

  @dialyzer {:no_return, start_link: 1}

  def child_spec(%Project{} = project) do
    %{
      id: {__MODULE__, Project.name(project)},
      start: {__MODULE__, :start_link, [project]}
    }
  end

  def start_link(%Project{} = project) do
    DynamicSupervisor.start_link(__MODULE__, project, name: __MODULE__, strategy: :one_for_one)
  end

  def start_project_node(%Project{} = project) do
    DynamicSupervisor.start_child(__MODULE__, EngineNode.child_spec(project))
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
