defmodule Engine.Commands.Reindex do
  defmodule State do
    alias Engine.Search
    alias Engine.Search.Indexer
    alias Forge.Ast.Analysis
    alias Forge.Document
    alias Forge.ProcessCache

    require Logger
    require ProcessCache

    defstruct reindex_fun: nil, index_task: nil, pending_updates: %{}

    def new(reindex_fun) do
      %__MODULE__{reindex_fun: reindex_fun}
    end

    def set_task(%__MODULE__{} = state, {_, _} = task) do
      %__MODULE__{state | index_task: task}
    end

    def clear_task(%__MODULE__{} = state) do
      %__MODULE__{state | index_task: nil}
    end

    def reindex_uri(%__MODULE__{index_task: nil} = state, uri) do
      case entries_for_uri(uri) do
        {:ok, path, entries} ->
          Search.Store.update(path, entries)

        _ ->
          :ok
      end

      state
    end

    def reindex_uri(%__MODULE__{} = state, uri) do
      case entries_for_uri(uri) do
        {:ok, path, entries} ->
          put_in(state.pending_updates[path], entries)

        _ ->
          state
      end
    end

    def flush_pending_updates(%__MODULE__{} = state) do
      Enum.each(state.pending_updates, fn {path, entries} ->
        Search.Store.update(path, entries)
      end)

      %__MODULE__{state | pending_updates: %{}}
    end

    defp entries_for_uri(uri) do
      with {:ok, %Document{} = document, %Analysis{} = analysis} <- ensure_open(uri),
           {:ok, entries} <- Indexer.Quoted.index_with_cleanup(analysis) do
        {:ok, document.path, entries}
      else
        error ->
          Logger.error("Could not update index because #{inspect(error)}")
          error
      end
    end

    defp ensure_open(uri) do
      case Document.Store.fetch(uri, :analysis) do
        {:ok, %Document{} = document, analysis} ->
          {:ok, document, analysis}

        {:error, :not_open} ->
          # Sometimes, some operations are received long after the reindex is triggered,
          # such as new files after a batch rename
          with {:ok, _} <- Document.Store.open_temporary(uri) do
            Document.Store.fetch(uri, :analysis)
          end
      end
    end
  end

  @moduledoc """
  A simple genserver that prevents more than one reindexing job from running at the same time
  """

  alias Forge.Document
  alias Forge.EngineApi
  alias Forge.Project

  alias Engine.Search

  use GenServer
  import EngineApi.Messages

  def start_link(opts) do
    [reindex_fun: fun] = Keyword.validate!(opts, reindex_fun: &do_reindex/1)
    GenServer.start_link(__MODULE__, fun, name: __MODULE__)
  end

  def uri(uri) do
    GenServer.cast(__MODULE__, {:reindex_uri, uri})
  end

  def perform do
    perform(Engine.get_project())
  end

  def perform(%Project{} = project) do
    GenServer.call(__MODULE__, {:perform, project})
  end

  def running? do
    GenServer.call(__MODULE__, :running?)
  end

  @impl GenServer
  def init(reindex_fun) do
    Process.flag(:fullsweep_after, 5)
    schedule_gc()
    {:ok, State.new(reindex_fun)}
  end

  @impl GenServer
  def handle_call(:running?, _from, %State{index_task: index_task} = state) do
    {:reply, match?({_, _}, index_task), state}
  end

  def handle_call({:perform, project}, _from, %State{index_task: nil} = state) do
    index_task = spawn_monitor(fn -> state.reindex_fun.(project) end)
    {:reply, :ok, State.set_task(state, index_task)}
  end

  def handle_call({:perform, _project}, _from, state) do
    {:reply, {:error, "Already Running"}, state}
  end

  @impl GenServer
  def handle_cast({:reindex_uri, uri}, %State{} = state) do
    {:noreply, State.reindex_uri(state, uri)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{index_task: {pid, ref}} = state) do
    new_state =
      state
      |> State.flush_pending_updates()
      |> State.clear_task()

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:gc, %State{} = state) do
    :erlang.garbage_collect()
    schedule_gc()
    {:noreply, state}
  end

  defp do_reindex(%Project{} = project) do
    Engine.broadcast(project_reindex_requested(project: project))

    {elapsed_us, result} =
      :timer.tc(fn ->
        with {:ok, entries} <- Search.Indexer.create_index(project) do
          Search.Store.replace(entries)
        end
      end)

    Engine.broadcast(
      project_reindexed(project: project, elapsed_ms: round(elapsed_us / 1000), status: :success)
    )

    result
  end

  defp schedule_gc do
    Process.send_after(self(), :gc, :timer.seconds(5))
  end
end
