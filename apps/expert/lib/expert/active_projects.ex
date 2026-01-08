defmodule Expert.ActiveProjects do
  @moduledoc """
  A cache to keep track of active projects.

  Since GenLSP events happen asynchronously, we use an ets table to keep track of
  them and avoid race conditions when we try to update the list of active projects.
  """
  alias Forge.Project

  use GenServer

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []}
    }
  end

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    __MODULE__ = :ets.new(__MODULE__, [:set, :named_table, :public, read_concurrency: true])

    __MODULE__.Ready =
      :ets.new(__MODULE__.Ready, [:set, :named_table, :public, read_concurrency: true])

    {:ok, nil}
  end

  def projects do
    __MODULE__
    |> :ets.tab2list()
    |> Enum.map(fn {_, project} -> project end)
  end

  @spec find_by_root_uri(Forge.uri()) :: Project.t() | nil
  def find_by_root_uri(root_uri) do
    case :ets.lookup(__MODULE__, root_uri) do
      [{_, project}] -> project
      [] -> nil
    end
  end

  def add_projects(new_projects) when is_list(new_projects) do
    for new_project <- new_projects do
      # We use `:ets.insert_new/2` to avoid overwriting the cached project's entropy
      :ets.insert_new(__MODULE__, {new_project.root_uri, new_project})
    end
  end

  def remove_projects(removed_projects) when is_list(removed_projects) do
    for removed_project <- removed_projects do
      :ets.delete(__MODULE__, removed_project.root_uri)
    end
  end

  def set_projects(new_projects) when is_list(new_projects) do
    :ets.delete_all_objects(__MODULE__)
    add_projects(new_projects)
  end

  def set_ready(%Project{} = project, ready?) when is_boolean(ready?) do
    if ready? do
      :ets.insert(__MODULE__.Ready, {project.root_uri, true})
    else
      :ets.delete(__MODULE__.Ready, project.root_uri)
    end
  end

  def active?(%Project{} = project) do
    case :ets.lookup(__MODULE__.Ready, project.root_uri) do
      [{_, true}] -> true
      _ -> false
    end
  end
end
