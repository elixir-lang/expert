defmodule Engine.Search.Store.Backends.Ets.State do
  @moduledoc """
  An ETS based search backend

  This backend uses an ETS table to store its data using a schema defined in the schemas submodule.

  """
  alias Engine.Search.Store.Backends.Ets.Schema
  alias Engine.Search.Store.Backends.Ets.Schemas
  alias Engine.Search.Store.Backends.Ets.Wal
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @schema_order [
    Schemas.LegacyV0,
    Schemas.V1,
    Schemas.V2,
    Schemas.V3
  ]

  import Wal, only: :macros
  import Entry, only: :macros

  import Schemas.V3,
    only: [
      by_block_id: 1,
      query_by_id: 1,
      query_by_path: 1,
      query_structure: 1,
      query_by_subject: 1,
      structure: 1,
      to_subject: 1
    ]

  defstruct [:project, :table_name, :leader?, :leader_pid, :wal_state]

  def new_leader(%Project{} = project) do
    %__MODULE__{project: project, leader?: true, leader_pid: self()}
  end

  def new_follower(%Project{} = project, leader_pid) do
    %__MODULE__{project: project, leader?: false, leader_pid: leader_pid}
  end

  def prepare(%__MODULE__{leader?: true} = state) do
    {:ok, wal, table_name, result} = Schema.load(state.project, @schema_order)

    {{:ok, result}, %__MODULE__{state | table_name: table_name, wal_state: wal}}
  end

  def prepare(%__MODULE__{leader?: false}) do
    {:error, :not_leader}
  end

  def drop(%__MODULE__{leader?: true} = state) do
    Wal.truncate(state.wal_state)
    :ets.delete_all_objects(state.table_name)
  end

  def insert(%__MODULE__{leader?: true} = state, entries) do
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
    match_pattern =
      query_by_subject(
        subject: to_subject(subject),
        type: type,
        subtype: subtype
      )

    state.table_name
    |> :ets.match_object({match_pattern, :_})
    |> Enum.flat_map(fn {_, id_keys} ->
      id_keys
    end)
    |> MapSet.new()
    |> Enum.flat_map(&:ets.lookup_element(state.table_name, &1, 2))
  end

  def find_by_prefix(%__MODULE__{} = state, subject, type, subtype) do
    match_pattern =
      query_by_subject(
        subject: to_prefix(subject),
        type: type,
        subtype: subtype
      )

    state.table_name
    |> :ets.select([{{match_pattern, :_}, [], [:"$_"]}])
    |> Stream.flat_map(fn {_, id_keys} -> id_keys end)
    |> Stream.uniq()
    |> Enum.flat_map(&:ets.lookup_element(state.table_name, &1, 2))
  end

  @dialyzer {:nowarn_function, to_prefix: 1}

  defp to_prefix(prefix) when is_binary(prefix) do
    # what we really want to do here is convert the prefix to a improper list
    # like this: `'abc' -> [97, 98, 99 | :_]`, it's different from `'abc' ++ [:_]`
    # this is the required format for the `:ets.select` function.
    {last_char, others} = prefix |> String.to_charlist() |> List.pop_at(-1)
    others ++ [last_char | :_]
  end

  def siblings(%__MODULE__{} = state, %Entry{} = entry) do
    key = by_block_id(block_id: entry.block_id, path: entry.path)
    dbg(key)

    siblings =
      state.table_name
      |> :ets.lookup_element(key, 2)
      |> Enum.map(&:ets.lookup_element(state.table_name, &1, 2))
      |> List.flatten()
      |> Enum.filter(fn sibling ->
        case {is_block(entry), is_block(sibling)} do
          {same, same} -> true
          _ -> false
        end
      end)
      |> Enum.sort_by(& &1.id)
      |> Enum.uniq()

    {:ok, siblings}
  rescue
    ArgumentError ->
      :error
  end

  def parent(%__MODULE__{} = state, %Entry{} = entry) do
    with {:ok, structure} <- structure_for_path(state, entry.path),
         {:ok, child_path} <- child_path(structure, entry.block_id) do
      child_path =
        if is_block(entry) do
          # if we're a block, finding the first block will find us, so pop
          # our id off the path.
          tl(child_path)
        else
          child_path
        end

      find_first_by_block_id(state, child_path)
    end
  end

  def parent(%__MODULE__{}, :root) do
    :error
  end

  def find_by_ids(%__MODULE__{} = state, ids, type, subtype)
      when is_list(ids) do
    for id <- ids,
        match_pattern = match_id_key(id, type, subtype),
        {_key, entry} <- :ets.match_object(state.table_name, match_pattern) do
      entry
    end
    |> List.flatten()
  end

  def replace_all(%__MODULE__{leader?: true} = state, entries) do
    rows = Schema.entries_to_rows(entries, current_schema())

    {:ok, _, result} =
      with_wal state.wal_state do
        true = :ets.delete_all_objects(state.table_name)
        true = :ets.insert(state.table_name, rows)
        :ok
      end

    # When we replace everything, the old checkpoint is invalidated
    # so it makes sense to force a new one.
    Wal.checkpoint(state.wal_state)
    result
  end

  def delete_by_path(%__MODULE__{leader?: true} = state, path) do
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

  def destroy_all(%Project{} = project) do
    Wal.destroy_all(project)
  end

  def destroy(%__MODULE__{leader?: true, wal_state: %Wal{}} = state) do
    Wal.destroy(state.wal_state)
  end

  def destroy(%__MODULE__{leader?: true}) do
    :ok
  end

  def terminate(%__MODULE__{wal_state: %Wal{}} = state) do
    Wal.close(state.wal_state)
  end

  def terminate(%__MODULE__{}) do
    :ok
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
        {:ok, _} = success ->
          {:halt, success}

        _ ->
          {:cont, failure}
      end
    end)
  end

  def find_entry_by_id(%__MODULE__{} = state, id) do
    case find_by_ids(state, [id], :_, :_) do
      [entry] -> {:ok, entry}
      _ -> :error
    end
  end

  def structure_for_path(%__MODULE__{} = state, path) do
    key = structure(path: path)

    case :ets.lookup_element(state.table_name, key, 2) do
      [structure] -> {:ok, structure}
      _ -> :error
    end
  rescue
    ArgumentError ->
      :error
  end

  defp match_id_key(id, type, subtype) do
    {query_by_id(id: id, type: type, subtype: subtype), :_}
  end

  defp current_schema do
    List.last(@schema_order)
  end
end
