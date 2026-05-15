defmodule Expert.Search.Store.Backends.Ets do
  @behaviour Expert.Search.Store.Backend

  use GenServer

  alias Expert.EngineApi
  alias Expert.Search.Store.Backend
  alias Expert.Search.Store.Backends.Ets.State
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @impl Backend
  def new(%Project{} = project) do
    {:ok, Process.whereis(name(project))}
  end

  @impl Backend
  def prepare(pid), do: GenServer.call(pid, :prepare, :infinity)

  @impl Backend
  def insert(%Project{} = project, entries) do
    GenServer.call(name(project), {:insert, [entries]}, :infinity)
  end

  @impl Backend
  def drop(%Project{} = project), do: GenServer.call(name(project), {:drop, []})

  @impl Backend
  def destroy(%Project{} = project) do
    if pid = GenServer.whereis(name(project)) do
      GenServer.call(pid, {:destroy, []})
    end

    :ok
  end

  def destroy_all(%Project{} = project), do: State.destroy_all(project)

  @impl Backend
  def reduce(%Project{} = project, acc, reducer_fun) do
    GenServer.call(name(project), {:reduce, [acc, reducer_fun]}, :infinity)
  end

  @impl Backend
  def replace_all(%Project{} = project, entries) do
    GenServer.call(name(project), {:replace_all, [entries]}, :infinity)
  end

  @impl Backend
  def delete_by_path(%Project{} = project, path) do
    GenServer.call(name(project), {:delete_by_path, [path]})
  end

  @impl Backend
  def apply_index_update(%Project{} = project, updated_entries, paths_to_clear) do
    GenServer.call(name(project), {:apply_index_update, [updated_entries, paths_to_clear]})
  end

  @impl Backend
  def find_by_subject(%Project{} = project, subject, type, subtype) do
    GenServer.call(name(project), {:find_by_subject, [subject, type, subtype]})
  end

  @impl Backend
  def find_by_prefix(%Project{} = project, prefix, type, subtype) do
    GenServer.call(name(project), {:find_by_prefix, [prefix, type, subtype]})
  end

  @impl Backend
  def find_by_ids(%Project{} = project, ids, type, subtype) do
    GenServer.call(name(project), {:find_by_ids, [ids, type, subtype]})
  end

  @impl Backend
  def structure_for_path(%Project{} = project, path) do
    GenServer.call(name(project), {:structure_for_path, [path]})
  end

  @impl Backend
  def siblings(%Project{} = project, %Entry{} = entry) do
    GenServer.call(name(project), {:siblings, [entry]})
  end

  @impl Backend
  def parent(%Project{} = project, %Entry{} = entry) do
    GenServer.call(name(project), {:parent, [entry]})
  end

  def start_link(%Project{} = project) do
    start_link(project, [])
  end

  def start_link(%Project{} = project, opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, [project, opts], name: name(project))
  end

  def child_spec(%Project{} = project) do
    %{id: {__MODULE__, Project.unique_name(project)}, start: {__MODULE__, :start_link, [project]}}
  end

  def child_spec([%Project{} = project | opts]) when is_list(opts) do
    %{
      id: {__MODULE__, Project.unique_name(project)},
      start: {__MODULE__, :start_link, [project, opts]}
    }
  end

  def name(%Project{} = project), do: :"#{Project.unique_name(project)}::search_ets_backend"

  @impl GenServer
  def init([%Project{} = project, opts]) do
    Process.flag(:fullsweep_after, 5)
    schedule_gc()
    {:ok, State.new(project, runtime_versions(project, opts))}
  end

  @impl GenServer
  def handle_call(:prepare, _from, %State{} = state) do
    {reply, new_state} = State.prepare(state)
    {:reply, reply, new_state}
  end

  def handle_call({function_name, arguments}, _from, %State{} = state) do
    reply = apply(State, function_name, [state | arguments])
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info(:gc, %State{} = state) do
    :erlang.garbage_collect()
    schedule_gc()
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %State{} = state) do
    State.terminate(state)
    state
  end

  defp schedule_gc, do: Process.send_after(self(), :gc, :timer.seconds(5))

  defp runtime_versions(%Project{}, runtime_versions: runtime_versions), do: runtime_versions
  defp runtime_versions(%Project{} = project, _opts), do: EngineApi.runtime_versions(project)
end
