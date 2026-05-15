defmodule Expert.Search.Store.Backends.Ets.State do
  @moduledoc """
  ETS-backed search backend state.
  """

  import Expert.Search.Store.Backends.Ets.Schemas.V4,
    only: [
      by_block_id: 1,
      query_by_id: 1,
      query_by_path: 1,
      query_structure: 1,
      query_by_subject: 1,
      structure: 1,
      to_subject: 1
    ]

  import Expert.Search.Store.Backends.Ets.Wal, only: :macros
  import Forge.Search.Indexer.Entry, only: :macros

  alias Expert.Search.Store.Backends.Ets.Schema
  alias Expert.Search.Store.Backends.Ets.Schemas
  alias Expert.Search.Store.Backends.Ets.Wal
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  require Logger

  @schema_order [Schemas.LegacyV0, Schemas.V1, Schemas.V2, Schemas.V3, Schemas.V4]

  defstruct [:project, :runtime_versions, :table_name, :wal_state]

  def new(%Project{} = project, runtime_versions) do
    %__MODULE__{project: project, runtime_versions: runtime_versions}
  end

  def prepare(%__MODULE__{} = state) do
    case load_schema(state.project, state.runtime_versions) do
      {:ok, wal, table_name, result} ->
        {{:ok, result}, %__MODULE__{state | table_name: table_name, wal_state: wal}}

      {:error, _} = error ->
        {error, state}
    end
  end

  defp load_schema(%Project{} = project, runtime_versions) do
    case Schema.load(project, @schema_order, runtime_versions) do
      {:ok, _, _, _} = result ->
        result

      {:error, reason} ->
        Logger.warning("Could not load existing search index, rebuilding it: #{inspect(reason)}")
        destroy_all(project)
        Schema.load(project, @schema_order, runtime_versions)
    end
  end

  def drop(%__MODULE__{} = state) do
    Wal.truncate(state.wal_state)
    :ets.delete_all_objects(state.table_name)
  end

  def insert(%__MODULE__{} = state, entries) do
    rows = Schema.entries_to_rows(entries, current_schema())

    with_wal state.wal_state do
      true = :ets.insert(state.table_name, rows)
    end

    :ok
  end

  def reduce(%__MODULE__{} = state, acc, reducer_fun) do
    ets_reducer = fn
      {{:by_id, _, _, _}, entries}, acc when is_list(entries) ->
        Enum.reduce(entries, acc, reducer_fun)

      {{:by_id, _, _, _}, %Entry{} = entry}, acc ->
        reducer_fun.(entry, acc)

      _, acc ->
        acc
    end

    :ets.foldl(ets_reducer, acc, state.table_name)
  end

  def find_by_subject(%__MODULE__{} = state, subject, type, subtype) do
    match_pattern = query_by_subject(subject: to_subject(subject), type: type, subtype: subtype)

    state.table_name
    |> :ets.match_object({match_pattern, :_})
    |> Enum.flat_map(fn {_, id_keys} -> id_keys end)
    |> MapSet.new()
    |> Enum.map(&lookup_element(state.table_name, &1, 2))
    |> Enum.reject(&(&1 == :error))
    |> List.flatten()
  end

  def find_by_prefix(%__MODULE__{} = state, subject, type, subtype) do
    match_pattern = query_by_subject(subject: to_prefix(subject), type: type, subtype: subtype)

    state.table_name
    |> :ets.select([{{match_pattern, :_}, [], [:"$_"]}])
    |> Stream.flat_map(fn {_, id_keys} -> id_keys end)
    |> Stream.uniq()
    |> Enum.map(&lookup_element(state.table_name, &1, 2))
    |> Enum.reject(&(&1 == :error))
    |> List.flatten()
  end

  @dialyzer {:nowarn_function, to_prefix: 1}
  defp to_prefix(prefix) when is_binary(prefix) do
    {last_char, others} = prefix |> String.to_charlist() |> List.pop_at(-1)
    others ++ [last_char | :_]
  end

  def siblings(%__MODULE__{} = state, %Entry{} = entry) do
    key = by_block_id(block_id: entry.block_id, path: entry.path)

    case lookup_element(state.table_name, key, 2) do
      :error ->
        :error

      elements ->
        elements
        |> Enum.map(&lookup_element(state.table_name, &1, 2))
        |> Enum.reject(&(&1 == :error))
        |> List.flatten()
        |> Enum.filter(&same_block_type?(entry, &1))
        |> Enum.sort_by(& &1.id)
        |> Enum.uniq()
        |> then(&{:ok, &1})
    end
  end

  def parent(%__MODULE__{} = state, %Entry{} = entry) do
    with {:ok, structure} <- structure_for_path(state, entry.path),
         {:ok, child_path} <- child_path(structure, entry.block_id) do
      child_path = if is_block(entry), do: tl(child_path), else: child_path
      find_first_by_block_id(state, child_path)
    end
  end

  def parent(%__MODULE__{}, :root), do: :error

  def find_by_ids(%__MODULE__{} = state, ids, type, subtype) when is_list(ids) do
    for id <- ids,
        match_pattern = match_id_key(id, type, subtype),
        {_key, entry} <- :ets.match_object(state.table_name, match_pattern) do
      entry
    end
    |> List.flatten()
  end

  def replace_all(%__MODULE__{} = state, entries) do
    rows = Schema.entries_to_rows(entries, current_schema())

    {:ok, _, result} =
      with_wal state.wal_state do
        true = :ets.delete_all_objects(state.table_name)
        true = :ets.insert(state.table_name, rows)
        :ok
      end

    Wal.checkpoint(state.wal_state)
    result
  end

  def delete_by_path(%__MODULE__{} = state, path) do
    ids_to_delete =
      state.table_name
      |> :ets.match({query_by_path(path: path), :"$0"})
      |> List.flatten()

    with_wal state.wal_state do
      :ets.match_delete(state.table_name, {query_by_subject(path: path), :_})
      :ets.match_delete(state.table_name, {query_by_path(path: path), :_})
      :ets.match_delete(state.table_name, {query_structure(path: path), :_})
    end

    Enum.each(ids_to_delete, fn id ->
      with_wal state.wal_state do
        :ets.delete(state.table_name, id)
      end
    end)

    {:ok, ids_to_delete}
  end

  def apply_index_update(%__MODULE__{} = state, updated_entries, paths_to_clear) do
    paths = affected_paths(updated_entries, paths_to_clear)

    ids_to_delete =
      Enum.flat_map(paths, fn path ->
        {:ok, deleted_ids} = delete_by_path(state, path)
        deleted_ids
      end)

    with :ok <- insert(state, updated_entries) do
      {:ok, Enum.map(ids_to_delete, &entry_id/1)}
    end
  end

  def destroy_all(%Project{} = project), do: Wal.destroy_all(project)

  def destroy(%__MODULE__{wal_state: %Wal{}} = state), do: Wal.destroy(state.wal_state)
  def destroy(%__MODULE__{}), do: :ok

  def terminate(%__MODULE__{wal_state: %Wal{}} = state), do: Wal.close(state.wal_state)
  def terminate(%__MODULE__{}), do: :ok

  def find_entry_by_id(%__MODULE__{} = state, id) do
    case find_by_ids(state, [id], :_, :_) do
      [entry] -> {:ok, entry}
      _ -> :error
    end
  end

  def structure_for_path(%__MODULE__{} = state, path) do
    key = structure(path: path)

    case lookup_element(state.table_name, key, 2) do
      [structure] -> {:ok, structure}
      _ -> :error
    end
  end

  defp child_path(structure, child_id) do
    path =
      Enum.reduce_while(structure, [], fn
        {^child_id, _children}, children ->
          {:halt, [child_id | children]}

        {_, children}, path when map_size(children) == 0 ->
          {:cont, path}

        {current_id, children}, path ->
          case child_path(children, child_id) do
            {:ok, child_path} -> {:halt, [current_id | path] ++ Enum.reverse(child_path)}
            :error -> {:cont, path}
          end
      end)

    case path do
      [] -> :error
      path -> {:ok, Enum.reverse(path)}
    end
  end

  defp find_first_by_block_id(%__MODULE__{} = state, block_ids) do
    Enum.reduce_while(block_ids, :error, fn block_id, failure ->
      case find_entry_by_id(state, block_id) do
        {:ok, _} = success -> {:halt, success}
        _ -> {:cont, failure}
      end
    end)
  end

  defp lookup_element(table_name, key, pos) do
    :ets.lookup_element(table_name, key, pos)
  rescue
    ArgumentError -> :error
  end

  defp affected_paths(updated_entries, paths_to_clear) do
    (Enum.map(updated_entries, & &1.path) ++ paths_to_clear)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp entry_id({:by_id, id, _type, _subtype}), do: id
  defp entry_id(id), do: id

  defp same_block_type?(a, b), do: is_block(a) == is_block(b)

  defp match_id_key(id, type, subtype),
    do: {query_by_id(id: id, type: type, subtype: subtype), :_}

  defp current_schema, do: List.last(@schema_order)
end
