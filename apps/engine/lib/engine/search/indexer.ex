defmodule Engine.Search.Indexer do
  alias Engine.Progress
  alias Engine.Search.Indexer
  alias Forge.Identifier
  alias Forge.ProcessCache
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  require ProcessCache

  @indexable_extensions "*.{ex,exs}"

  def create_index(%Project{} = project) do
    ProcessCache.with_cleanup do
      deps_dir = deps_dir()

      entries =
        project
        |> indexable_files()
        |> async_chunks(&index_path(&1, deps_dir))

      {:ok, entries}
    end
  end

  def update_index(%Project{} = project, backend) do
    ProcessCache.with_cleanup do
      do_update_index(project, backend)
    end
  end

  defp do_update_index(%Project{} = project, backend) do
    path_to_ids =
      backend.reduce(%{}, fn
        %Entry{path: path} = entry, path_to_ids when is_integer(entry.id) ->
          Map.update(path_to_ids, path, entry.id, &max(&1, entry.id))

        _entry, path_to_ids ->
          path_to_ids
      end)

    project_files =
      project
      |> indexable_files()
      |> MapSet.new()

    previously_indexed_paths = MapSet.new(path_to_ids, fn {path, _} -> path end)

    new_paths = MapSet.difference(project_files, previously_indexed_paths)

    {paths_to_examine, paths_to_delete} =
      Enum.split_with(path_to_ids, fn {path, _} -> File.regular?(path) end)

    changed_paths =
      for {path, id} <- paths_to_examine,
          newer_than?(path, id) do
        path
      end

    paths_to_delete = Enum.map(paths_to_delete, &elem(&1, 0))

    paths_to_reindex = changed_paths ++ Enum.to_list(new_paths)

    entries = async_chunks(paths_to_reindex, &index_path(&1, deps_dir()))

    {:ok, entries, paths_to_delete}
  end

  defp index_path(path, deps_dir) do
    with {:ok, contents} <- File.read(path),
         {:ok, entries} <- Indexer.Source.index(path, contents) do
      Enum.filter(entries, fn entry ->
        if Forge.Path.contains?(path, deps_dir) do
          entry.subtype == :definition
        else
          true
        end
      end)
    else
      _ ->
        []
    end
  end

  # 128 K blocks indexed expert in 5.3 seconds
  @bytes_per_block 1024 * 128
  defp async_chunks(file_paths, processor, timeout \\ :infinity) do
    # this function tries to even out the amount of data processed by
    # async stream by making each chunk emitted by the initial stream to
    # be roughly equivalent

    # Shuffling the results helps speed in some projects, as larger files tend to clump
    # together, like when there are auto-generated elixir modules.
    paths_to_sizes =
      file_paths
      |> path_to_sizes()
      |> Enum.shuffle()

    path_to_size_map = Map.new(paths_to_sizes)

    total_bytes = paths_to_sizes |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if total_bytes > 0 do
      {on_update_progress, on_complete} =
        Progress.begin_percent("Indexing source code", total_bytes)

      initial_state = {0, []}

      chunk_fn = fn {path, file_size}, {block_size, paths} ->
        new_block_size = file_size + block_size
        new_paths = [path | paths]

        if new_block_size >= @bytes_per_block do
          {:cont, new_paths, initial_state}
        else
          {:cont, {new_block_size, new_paths}}
        end
      end

      after_fn = fn
        {_, []} ->
          {:cont, []}

        {_, paths} ->
          {:cont, paths, []}
      end

      paths_to_sizes
      |> Stream.chunk_while(initial_state, chunk_fn, after_fn)
      |> Task.async_stream(
        fn chunk ->
          block_bytes = chunk |> Enum.map(&Map.get(path_to_size_map, &1)) |> Enum.sum()
          result = Enum.map(chunk, processor)
          on_update_progress.(block_bytes, "Indexing")
          result
        end,
        timeout: timeout
      )
      |> Stream.flat_map(fn
        {:ok, entry_chunks} -> entry_chunks
        _ -> []
      end)
      # The next bit is the only way i could figure out how to
      # call complete once the stream was realized
      |> Stream.transform(
        fn -> nil end,
        fn chunk_items, acc ->
          # By the chunk items list directly, each transformation
          # will flatten the resulting steam
          {chunk_items, acc}
        end,
        fn _acc ->
          on_complete.()
        end
      )
    else
      []
    end
  end

  defp path_to_sizes(paths) do
    Enum.reduce(paths, [], fn file_path, acc ->
      case File.stat(file_path) do
        {:ok, %File.Stat{} = stat} ->
          [{file_path, stat.size} | acc]

        _ ->
          acc
      end
    end)
  end

  defp newer_than?(path, entry_id) do
    case stat(path) do
      {:ok, %File.Stat{} = stat} ->
        stat.mtime > Identifier.to_erl(entry_id)

      _ ->
        false
    end
  end

  def indexable_files(%Project{} = project) do
    root_dir = Project.root_path(project)
    build_dir = build_dir()

    [root_dir, "**", @indexable_extensions]
    |> Forge.Path.glob()
    |> Enum.reject(&Forge.Path.contains?(&1, build_dir))
  end

  # stat(path) is here for testing so it can be mocked
  defp stat(path) do
    File.stat(path)
  end

  defp deps_dir do
    case Engine.Mix.in_project(&Mix.Project.deps_path/0) do
      {:ok, path} -> path
      _ -> Mix.Project.deps_path()
    end
  end

  defp build_dir do
    case Engine.Mix.in_project(&Mix.Project.build_path/0) do
      {:ok, path} -> path
      _ -> Mix.Project.build_path()
    end
  end
end
