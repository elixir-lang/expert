defmodule Expert.Project.Store do
  @moduledoc """
  Tracks which projects are known and what status each is in.
  """
  use GenServer

  alias Forge.Project

  @table __MODULE__

  @type status :: :pending | :ready | :blocked

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []}
    }
  end

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    @table = :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  @spec projects() :: [Project.t()]
  def projects do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_root_uri, project, _status} -> project end)
  end

  @doc """
  Looks up a project by its root URI. Returns nil if not found.
  """
  @spec find_by_root_uri(Forge.uri()) :: Project.t() | nil
  def find_by_root_uri(root_uri) do
    case :ets.lookup(@table, root_uri) do
      [{_root_uri, project, _status}] -> project
      [] -> nil
    end
  end

  @doc """
  Inserts new projects with `:pending` status.
  """
  @spec add_projects([Project.t()]) :: :ok
  def add_projects(new_projects) when is_list(new_projects) do
    for %Project{} = project <- new_projects do
      :ets.insert_new(@table, {project.root_uri, project, :pending})
    end

    :ok
  end

  @spec remove_projects([Project.t()]) :: :ok
  def remove_projects(removed_projects) when is_list(removed_projects) do
    for %Project{} = project <- removed_projects do
      :ets.delete(@table, project.root_uri)
    end

    :ok
  end

  @doc """
  Clears the table and populates it with the given projects.
  """
  @spec set_projects([Project.t()]) :: :ok
  def set_projects(new_projects) when is_list(new_projects) do
    :ets.delete_all_objects(@table)
    add_projects(new_projects)
  end

  @spec ready?(Project.t()) :: boolean()
  def ready?(%Project{} = project) do
    case :ets.lookup(@table, project.root_uri) do
      [{_root_uri, _project, :ready}] -> true
      _ -> false
    end
  end

  @spec blocked?(Project.t()) :: boolean()
  def blocked?(%Project{} = project) do
    case :ets.lookup(@table, project.root_uri) do
      [{_root_uri, _project, :blocked}] -> true
      _ -> false
    end
  end

  @doc """
  Transitions a project to the given status.

  Returns `true` if the project was found and updated, `false` if the
  project is not tracked.
  """
  @spec transition(Project.t(), status()) :: boolean()
  def transition(%Project{} = project, status) when status in [:pending, :ready, :blocked] do
    :ets.update_element(@table, project.root_uri, {3, status})
  end
end
