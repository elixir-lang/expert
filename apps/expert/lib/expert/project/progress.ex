defmodule Expert.Project.Progress do
  alias Expert.Project.Progress.State
  alias Forge.Project

  import Forge.EngineApi.Messages

  use GenServer

  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, [project], name: name(project))
  end

  def child_spec(%Project{} = project) do
    %{
      id: {__MODULE__, Project.name(project)},
      start: {__MODULE__, :start_link, [project]}
    }
  end

  # GenServer callbacks

  @impl GenServer
  def init([project]) do
    {:ok, State.new(project)}
  end

  @impl true
  def handle_info(project_progress(stage: stage) = message, %State{} = state) do
    new_state = apply(State, stage, [state, message])
    {:noreply, new_state}
  end

  def handle_info(percent_progress(stage: stage) = message, %State{} = state) do
    new_state = apply(State, stage, [state, message])

    {:noreply, new_state}
  end

  def name(%Project{} = project) do
    :"#{Project.name(project)}::progress"
  end

  def whereis(%Project{} = project) do
    project |> name() |> Process.whereis()
  end
end
