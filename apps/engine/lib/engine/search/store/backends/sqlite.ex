defmodule Engine.Search.Store.Backends.Sqlite do
  alias Engine.Search.Store.Backend
  alias Engine.Search.Store.Backends.Sqlite.State
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @behaviour Backend

  use GenServer

  @impl Backend
  def new(%Project{} = _project) do
    {:ok, Process.whereis(__MODULE__)}
  end

  @impl Backend
  def prepare(pid) do
    GenServer.call(pid, {:prepare, []}, :infinity)
  end

  @impl Backend
  def sync(%Project{} = _project) do
    :ok
  end

  @impl Backend
  def insert(entries) do
    GenServer.call(__MODULE__, {:insert, [entries]})
  end

  @impl Backend
  def drop() do
    GenServer.call(__MODULE__, {:drop, []})
  end

  @impl Backend
  def destroy(%Project{} = project) do
    File.rm_rf!(State.db_file(project))

    if pid = GenServer.whereis(__MODULE__) do
      GenServer.call(pid, {:destroy, [project]})
    end

    :ok
  end

  @impl Backend
  def reduce(accumulator, reducer_fun) do
    GenServer.call(__MODULE__, {:reduce, [accumulator, reducer_fun]})
  end

  @impl Backend
  def replace_all(entries) do
    GenServer.call(__MODULE__, {:replace_all, [entries]})
  end

  @impl Backend
  def delete_by_path(path) do
    GenServer.call(__MODULE__, {:delete_by_path, [path]})
  end

  @impl Backend
  def structure_for_path(path) do
    GenServer.call(__MODULE__, {:structure_for_path, [path]})
  end

  @impl Backend
  def find_by_subject(subject_query, type_query, subtype_query) do
    GenServer.call(__MODULE__, {:find_by_subject, [subject_query, type_query, subtype_query]})
  end

  @impl Backend
  def find_by_prefix(subject_query, type_query, subtype_query) do
    GenServer.call(__MODULE__, {:find_by_prefix, [subject_query, type_query, subtype_query]})
  end

  @impl Backend
  def find_by_ids(entry_ids, type_query, subtype_query) do
    GenServer.call(__MODULE__, {:find_by_ids, [entry_ids, type_query, subtype_query]})
  end

  @impl Backend
  def siblings(%Entry{} = entry) do
    GenServer.call(__MODULE__, {:siblings, [entry]})
  end

  @impl Backend
  def parent(%Entry{} = entry) do
    GenServer.call(__MODULE__, {:parent, [entry]})
  end

  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, [project], name: __MODULE__)
  end

  def start_link do
    project = Engine.get_project()
    start_link(project)
  end

  def child_spec([%Project{}] = init_args) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, init_args}}
  end

  def child_spec(_) do
    child_spec([Engine.get_project()])
  end

  @impl GenServer
  def init([%Project{} = project]) do
    file = State.db_file(project)
    Exqlite.Basic.open(file)
  end

  @impl GenServer
  def handle_call({function_name, arguments}, _from, conn) do
    arguments = [conn | arguments]
    reply = apply(State, function_name, arguments)
    {:reply, reply, conn}
  end
end
