defmodule Engine.Search.Store.Backends.Ets.Wal do
  @moduledoc """
  A (hopefully) simple write-ahead log
  """
  alias Engine.Progress
  alias Forge.Identifier
  alias Forge.Project
  alias Forge.VM.Versions

  import Record

  defrecord :operation, id: nil, function: nil, args: nil

  defstruct [
    :checkpoint_version,
    :ets_table,
    :max_wal_operations,
    :project,
    :schema_version,
    :update_log,
    :update_log_name
  ]

  @write_functions [
    :delete,
    :delete_all_objects,
    :delete_object,
    :insert,
    :insert_new,
    :match_delete,
    :select_delete,
    :select_replace,
    :update_counter,
    :update_element
  ]

  @no_checkpoint_id 0
  @chunk_size 10_000
  @checkpoint_int_length 20
  @default_max_operations 50_000

  defmacro with_wal(wal_state, do: block) do
    {_, write_calls} =
      Macro.prewalk(block, [], fn ast, acc ->
        {ast, collect_ets_writes(ast, acc)}
      end)

    operations =
      write_calls
      |> Enum.reverse()
      |> Enum.map(&to_operation/1)

    quote do
      case unquote(__MODULE__).append(unquote(wal_state), unquote(operations)) do
        {:ok, wal_state} ->
          result = unquote(block)
          {:ok, wal_state, result}

        error ->
          error
      end
    end
  end

  def load(%Project{} = project, schema_version, ets_table, options \\ []) do
    max_wal_operations = Keyword.get(options, :max_wal_operations, @default_max_operations)

    wal = %__MODULE__{
      ets_table: ets_table,
      max_wal_operations: max_wal_operations,
      project: project,
      schema_version: to_string(schema_version)
    }

    ensure_wal_directory_exists(wal)

    with {:ok, checkpoint_id} <- load_latest_checkpoint(wal),
         {:ok, new_wal} <- open_update_wal(wal, checkpoint_id),
         :ok <- apply_updates(new_wal) do
      {:ok, new_wal}
    end
  end

  def exists?(%__MODULE__{} = wal) do
    exists?(wal.project, wal.schema_version)
  end

  def exists?(%Project{} = project, schema_version) do
    case File.ls(wal_directory(project, schema_version)) do
      {:ok, [_]} -> true
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  def append(%__MODULE__{} = wal, operations) do
    case :disk_log.log_terms(wal.update_log, operations) do
      :ok ->
        maybe_checkpoint(wal)

      error ->
        error
    end
  end

  def close(%__MODULE__{} = wal) do
    case wal.update_log do
      nil ->
        :ok

      log ->
        :disk_log.sync(log)
        :disk_log.close(log)
    end
  end

  def truncate(%__MODULE__{} = wal) do
    :disk_log.truncate(wal.update_log)
  end

  def destroy(%__MODULE__{} = wal) do
    close(wal)
    destroy(wal.project, wal.schema_version)
  end

  def destroy(%Project{} = project, schema_version) do
    project
    |> wal_directory(schema_version)
    |> File.rm_rf!()
  end

  def destroy_all(%Project{} = project) do
    project
    |> root_path()
    |> File.rm_rf!()
  end

  def checkpoint(%__MODULE__{} = wal) do
    case :ets.info(wal.ets_table) do
      :undefined ->
        {:error, :no_table}

      _ ->
        do_checkpoint(wal)
    end
  end

  def size(%__MODULE__{update_log: nil}) do
    {:error, :not_loaded}
  end

  def size(%__MODULE__{update_log: update_log}) do
    with info when is_list(info) <- :disk_log.info(update_log),
         {:ok, size} <- Keyword.fetch(info, :items) do
      {:ok, size}
    else
      _ ->
        {:error, :not_loaded}
    end
  end

  def root_path(%Project{} = project) do
    Project.workspace_path(project, ["indexes", "ets"])
  end

  # Private

  defp collect_ets_writes({{:., _, [:ets, function_name]}, _, args}, acc)
       when function_name in @write_functions do
    [{:ets, function_name, args} | acc]
  end

  defp collect_ets_writes(_, acc), do: acc

  defp to_operation({:ets, call_name, args}) do
    quote do
      operation(id: Identifier.next_global!(), function: unquote(call_name), args: unquote(args))
    end
  end

  defp ensure_wal_directory_exists(%__MODULE__{} = wal) do
    wal |> wal_directory() |> File.mkdir_p!()
  end

  defp wal_directory(%__MODULE__{} = wal) do
    wal_directory(wal.project, wal.schema_version)
  end

  defp wal_directory(%Project{} = project, schema_version) do
    versions = Versions.current()
    Path.join([root_path(project), versions.erlang, versions.elixir, to_string(schema_version)])
  end

  defp open_update_wal(%__MODULE__{} = wal, checkpoint_version) do
    wal_path = update_wal_path(wal)
    wal_name = update_wal_name(wal)

    case :disk_log.open(name: wal_name, file: String.to_charlist(wal_path)) do
      {:ok, log} ->
        new_wal = %__MODULE__{
          wal
          | update_log: log,
            update_log_name: wal_name,
            checkpoint_version: checkpoint_version
        }

        {:ok, new_wal}

      {:repaired, log, {:recovered, _}, _bad} ->
        new_wal = %__MODULE__{
          wal
          | update_log: log,
            update_log_name: wal_name,
            checkpoint_version: checkpoint_version
        }

        {:ok, new_wal}

      error ->
        error
    end
  end

  defp update_wal_name(%__MODULE__{} = wal) do
    :"updates_for_#{Project.name(wal.project)}_v#{wal.schema_version}"
  end

  # Updates
  defp apply_updates(%__MODULE__{} = wal) do
    stream_updates(wal, wal.update_log, :start)
  end

  defp stream_updates(%__MODULE__{} = wal, log, continuation) do
    case :disk_log.chunk(log, continuation, @chunk_size) do
      {continuation, items} when is_list(items) ->
        apply_relevant_items(wal, items)
        stream_updates(wal, log, continuation)

      {continuation, items, _bad_bytes} ->
        apply_relevant_items(wal, items)
        stream_updates(wal, log, continuation)

      :eof ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp apply_relevant_items(%__MODULE__{} = wal, items) do
    checkpoint_version = wal.checkpoint_version

    items
    |> Stream.filter(fn operation(id: id) -> id >= checkpoint_version end)
    |> Enum.each(fn operation(function: function, args: args) ->
      apply(:ets, function, args)
    end)
  end

  defp get_wal_operations(%__MODULE__{} = wal) do
    stats = :disk_log.info(wal.update_log)
    Keyword.get(stats, :items, 0)
  end

  # Checkpoints
  defp needs_checkpoint?(%__MODULE__{} = wal) do
    get_wal_operations(wal) >= wal.max_wal_operations
  end

  defp maybe_checkpoint(%__MODULE__{} = wal) do
    with true <- needs_checkpoint?(wal),
         {:ok, new_wal} <- checkpoint(wal) do
      {:ok, new_wal}
    else
      _ ->
        {:ok, wal}
    end
  end

  defp do_checkpoint(%__MODULE__{} = wal) do
    checkpoint_version = Identifier.next_global!()
    checkpoint_file_name = checkpoint_file_name(checkpoint_version)

    log_path = wal |> wal_directory() |> Path.join(checkpoint_file_name)
    log_name = checkpoint_log_name(wal.project)

    with {:ok, log} <- :disk_log.open(name: log_name, file: String.to_charlist(log_path)),
         :ok <- checkpoint_ets_table(wal, log),
         :ok <- :disk_log.close(log),
         :ok <- :disk_log.truncate(wal.update_log) do
      new_wal = %__MODULE__{wal | checkpoint_version: checkpoint_version}
      delete_old_checkpoints(new_wal)
      {:ok, new_wal}
    else
      error ->
        # Checkpoint loading failed. Give up and start over
        delete_old_checkpoints(wal)
        error
    end
  end

  defp checkpoint_ets_table(%__MODULE__{} = wal, log) do
    log_chunks = fn
      item, {@chunk_size, items} ->
        :disk_log.log_terms(log, Enum.reverse(items))
        {1, [item]}

      item, {count, items} ->
        {count + 1, [item | items]}
    end

    {_count, items} = :ets.foldl(log_chunks, {0, []}, wal.ets_table)
    :disk_log.log_terms(log, Enum.reverse(items))
  end

  defp load_latest_checkpoint(%__MODULE__{} = wal) do
    with {:ok, checkpoint_file} <- find_latest_checkpoint(wal),
         {:ok, checkpoint_version} <- extract_checkpoint_version(checkpoint_file),
         :ok <- load_checkpoint(wal, checkpoint_file) do
      {:ok, checkpoint_version}
    else
      _ ->
        # There's no checkpoint, or our checkpoint is invalid. Start from scratch.
        {:ok, @no_checkpoint_id}
    end
  end

  defp load_checkpoint(%__MODULE__{} = wal, checkpoint_file) do
    log_name = checkpoint_log_name(wal.project)

    case :disk_log.open(name: log_name, file: String.to_charlist(checkpoint_file)) do
      {:ok, log} ->
        stream_checkpoint_with_progress(wal, log)

      {:repaired, log, _recovered, _bad_bytes} ->
        stream_checkpoint_with_progress(wal, log)

      error ->
        error
    end
  end

  defp delete_old_checkpoints(%__MODULE__{} = wal) do
    current_checkpoint_file_name = checkpoint_file_name(wal.checkpoint_version)

    [wal_directory(wal), "*.checkpoint"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.each(fn checkpoint ->
      if Path.basename(checkpoint) != current_checkpoint_file_name do
        File.rm(checkpoint)
      end
    end)
  end

  defp checkpoint_file_name(checkpoint_id) when is_integer(checkpoint_id) do
    checkpoint_id
    |> Integer.to_string(10)
    |> checkpoint_file_name()
  end

  defp checkpoint_file_name(checkpoint_id) when is_binary(checkpoint_id) do
    String.pad_leading(checkpoint_id, @checkpoint_int_length, "0") <> ".checkpoint"
  end

  defp checkpoint_log_name(%Project{} = project) do
    :"checkpoint_log_#{Project.name(project)}"
  end

  defp stream_checkpoint_with_progress(%__MODULE__{} = wal, log) do
    Progress.with_progress("Loading search index", fn _token ->
      result = stream_checkpoint(wal, log, :start)
      {:done, result}
    end)
  end

  defp stream_checkpoint(%__MODULE__{} = wal, log, continuation) do
    case :disk_log.chunk(log, continuation, @chunk_size) do
      {continuation, items} when is_list(items) ->
        :ets.insert(wal.ets_table, items)
        stream_checkpoint(wal, log, continuation)

      {continuation, items, _bad_bytes} ->
        :ets.insert(wal.ets_table, items)
        stream_checkpoint(wal, log, continuation)

      :eof ->
        :disk_log.close(log)
        :ok

      {:error, _} = error ->
        :disk_log.close(log)
        error
    end
  end

  defp find_latest_checkpoint(%__MODULE__{} = wal) do
    checkpoints =
      [wal_directory(wal), "*.checkpoint"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.sort(:desc)

    case checkpoints do
      [checkpoint | _] ->
        {:ok, checkpoint}

      _ ->
        {:error, :no_checkpoint}
    end
  end

  defp extract_checkpoint_version(checkpoint_path) do
    file_name = Path.basename(checkpoint_path)

    with [id_string, _] <- String.split(file_name, "."),
         {id, ""} <- Integer.parse(id_string, 10) do
      {:ok, id}
    else
      _ ->
        :error
    end
  end

  defp update_wal_path(%__MODULE__{} = wal) do
    wal
    |> wal_directory()
    |> Path.join("updates.wal")
  end
end
