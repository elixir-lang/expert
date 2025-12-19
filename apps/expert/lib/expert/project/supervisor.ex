defmodule Expert.Project.Supervisor do
  alias Expert.ActiveProjects
  alias Expert.EngineSupervisor
  alias Expert.Project.Diagnostics
  alias Expert.Project.Intelligence
  alias Expert.Project.Node
  alias Expert.Project.Progress
  alias Expert.Project.SearchListener
  alias Forge.Project

  require Logger

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

  def name(%Project{} = project) do
    :"#{Project.name(project)}::supervisor"
  end

  def ensure_node_started(%Project{} = project) do
    case start(project) do
      {:ok, pid} ->
        ActiveProjects.set_ready(project, true)
        Logger.info("Project node started for #{Project.name(project)}")

        GenLSP.log(Expert.get_lsp(), "Started project node for #{Project.name(project)}")
        {:ok, pid}

      {:error, {reason, pid}} when reason in [:already_started, :already_present] ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error(
          "Failed to start project node for #{Project.name(project)}: #{inspect(reason, pretty: true)}"
        )

        GenLSP.error(
          Expert.get_lsp(),
          "Failed to start project node for #{Project.name(project)}: #{inspect(reason, pretty: true)}"
        )

        {:error, reason}
    end
  end

  def stop_node(%Project{} = project) do
    stop(project)
    ActiveProjects.set_ready(project, false)

    GenLSP.log(
      Expert.get_lsp(),
      "Stopping project node for #{Project.name(project)}"
    )
  end
end
