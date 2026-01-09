defmodule Engine.Search.Store.State do
  alias Engine.Dispatch
  alias Engine.Search.Fuzzy
  alias Forge.EngineApi.Messages
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  require Logger
  import Messages

  defstruct [
    :project,
    :backend,
    :create_index,
    :update_index,
    :loaded?,
    :fuzzy,
    :async_load_ref,
    :update_buffer
  ]

  def new(%Project{} = project, create_index, update_index, backend) do
    %__MODULE__{
      backend: backend,
      create_index: create_index,
      project: project,
      loaded?: false,
      update_index: update_index,
      update_buffer: %{},
      fuzzy: Fuzzy.from_entries([])
    }
  end

  def drop(%__MODULE__{} = state) do
    state.backend.drop()
  end

  def destroy(%__MODULE__{} = state) do
    state.backend.destroy(state)
  end

  @doc """
  Asynchronously loads the search state.

  This function returns prior to creating or refreshing the index, which
  occurs in a separate process. The caller should listen for a message
  of the shape `{ref, result}`, where `ref` matches the state's
  `:async_load_ref`. Once received, that result should be passed to
  `async_load_complete/2`.
  """
  def async_load(%__MODULE__{loaded?: false, async_load_ref: nil} = state) do
    {:ok, backend_result} = state.backend.new(state.project)
    prepare_backend_async(state, backend_result)
  end

  def async_load(%__MODULE__{} = state) do
    {:ok, state}
  end

  def async_load_complete(%__MODULE__{} = state, result) do
    new_state = %__MODULE__{state | loaded?: true, async_load_ref: nil}

    response =
      case result do
        {:create_index, result} ->
          create_index_complete(new_state, result)

        {:update_index, result} ->
          update_index_complete(new_state, result)

        :initialize_fuzzy ->
          initialize_fuzzy(new_state)
      end

    Dispatch.broadcast(project_index_ready(project: state.project))
    response
  end

  def replace(%__MODULE__{} = state, entries) do
    with :ok <- state.backend.replace_all(entries),
         :ok <- maybe_sync(state) do
      {:ok, %__MODULE__{state | fuzzy: Fuzzy.from_backend(state.backend)}}
    end
  end

  def exact(%__MODULE__{} = state, subject, constraints) do
    type = Keyword.get(constraints, :type, :_)
    subtype = Keyword.get(constraints, :subtype, :_)

    case state.backend.find_by_subject(subject, type, subtype) do
      l when is_list(l) -> {:ok, l}
      error -> error
    end
  end

  def prefix(%__MODULE__{} = state, prefix, constraints) do
    type = Keyword.get(constraints, :type, :_)
    subtype = Keyword.get(constraints, :subtype, :_)

    case state.backend.find_by_prefix(prefix, type, subtype) do
      l when is_list(l) ->
        {:ok, l}

      error ->
        error
    end
  end

  def fuzzy(%__MODULE__{} = state, subject, constraints) do
    case Fuzzy.match(state.fuzzy, subject) do
      [] ->
        {:ok, []}

      ids ->
        type = Keyword.get(constraints, :type, :_)
        subtype = Keyword.get(constraints, :subtype, :_)

        case state.backend.find_by_ids(ids, type, subtype) do
          l when is_list(l) -> {:ok, l}
          error -> error
        end
    end
  end

  def all(%__MODULE__{} = state, constraints) do
    type = Keyword.get(constraints, :type, :_)
    subtype = Keyword.get(constraints, :subtype, :_)

    entries =
      state.backend.reduce([], fn
        %Entry{} = entry, acc ->
          if matches_constraints?(entry, type, subtype) do
            [entry | acc]
          else
            acc
          end

        _, acc ->
          acc
      end)

    {:ok, entries}
  end

  defp matches_constraints?(%Entry{type: t, subtype: st}, type, subtype) do
    (type == :_ or t == type) and (subtype == :_ or st == subtype)
  end

  def siblings(%__MODULE__{} = state, entry) do
    case state.backend.siblings(entry) do
      l when is_list(l) -> {:ok, l}
      error -> error
    end
  end

  def parent(%__MODULE__{} = state, entry) do
    case state.backend.parent(entry) do
      %Entry{} = entry -> {:ok, entry}
      error -> error
    end
  end

  def buffer_updates(%__MODULE__{} = state, path, entries) do
    %__MODULE__{state | update_buffer: Map.put(state.update_buffer, path, entries)}
  end

  def drop_buffered_updates(%__MODULE__{} = state) do
    %__MODULE__{state | update_buffer: %{}}
  end

  def flush_buffered_updates(%__MODULE__{update_buffer: buffer} = state)
      when map_size(buffer) == 0 do
    maybe_sync(state)
    {:ok, state}
  end

  def flush_buffered_updates(%__MODULE__{} = state) do
    result =
      Enum.reduce_while(state.update_buffer, state, fn {path, entries}, state ->
        case update_nosync(state, path, entries) do
          {:ok, new_state} ->
            {:cont, new_state}

          error ->
            {:halt, error}
        end
      end)

    with %__MODULE__{} = state <- result,
         :ok <- maybe_sync(state) do
      {:ok, drop_buffered_updates(state)}
    end
  end

  def update_nosync(%__MODULE__{} = state, path, entries) do
    with {:ok, deleted_ids} <- state.backend.delete_by_path(path),
         :ok <- state.backend.insert(entries) do
      fuzzy =
        state.fuzzy
        |> Fuzzy.drop_values(deleted_ids)
        |> Fuzzy.add(entries)

      {:ok, %__MODULE__{state | fuzzy: fuzzy}}
    end
  end

  require Logger

  defp prepare_backend_async(%__MODULE__{async_load_ref: nil} = state, backend_result) do
    task =
      Task.async(fn ->
        case state.backend.prepare(backend_result) do
          {:ok, :empty} ->
            Logger.info("backend reports empty")
            {:create_index, state.create_index.(state.project)}

          {:ok, :stale} ->
            Logger.info("backend reports stale")
            {:update_index, state.update_index.(state.project, state.backend)}

          {:error, :not_leader} ->
            :initialize_fuzzy

          error ->
            Logger.error("Could not initialize index due to #{inspect(error)}")
            error
        end
      end)

    %__MODULE__{state | async_load_ref: task.ref}
  end

  defp create_index_complete(%__MODULE__{} = state, {:ok, entries}) do
    case replace(state, entries) do
      {:ok, state} ->
        state

      {:error, _} ->
        Logger.warning("Could not replace entries")
        state
    end
  end

  defp create_index_complete(%__MODULE__{} = state, {:error, _} = error) do
    Logger.warning("Could not create index, got: #{inspect(error)}")
    state
  end

  defp update_index_complete(%__MODULE__{} = state, {:ok, updated_entries, deleted_paths}) do
    starting_state = initialize_fuzzy(%__MODULE__{state | loaded?: true})

    new_state =
      updated_entries
      |> Enum.group_by(& &1.path)
      |> Enum.reduce(starting_state, fn {path, entry_list}, state ->
        {:ok, new_state} = update_nosync(state, path, entry_list)
        new_state
      end)

    Enum.reduce(deleted_paths, new_state, fn path, state ->
      {:ok, new_state} = update_nosync(state, path, [])
      new_state
    end)
  end

  defp update_index_complete(%__MODULE__{} = state, {:error, _} = error) do
    Logger.warning("Could not update index, got: #{inspect(error)}")
    state
  end

  defp maybe_sync(%__MODULE__{} = state) do
    if function_exported?(state.backend, :sync, 1) do
      state.backend.sync(state.project)
    else
      :ok
    end
  end

  defp initialize_fuzzy(%__MODULE__{} = state) do
    fuzzy = Fuzzy.from_backend(state.backend)

    %__MODULE__{state | fuzzy: fuzzy}
  end
end
