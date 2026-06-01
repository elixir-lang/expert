defmodule Engine.Search.Indexer do
  alias Engine.ApplicationCache
  alias Engine.Search.Indexer.Beams
  alias Engine.Search.Indexer.Manifest
  alias Engine.Search.Indexer.ManifestStore
  alias Engine.Search.Indexer.Paths
  alias Engine.Search.Indexer.Sources
  alias Forge.ProcessCache
  alias Forge.Project

  require Logger
  require ProcessCache

  def create_index(%Project{} = project, backend) when is_atom(backend) do
    with_indexer_context(fn ->
      {entries, manifest} = create_index_data(project)

      replace_index(project, backend, entries, manifest)
    end)
  end

  def update_index(%Project{} = project, backend) do
    with_indexer_context(fn ->
      case ManifestStore.load(project) do
        {:ok, %Manifest{} = manifest} -> refresh_index(project, manifest, backend)
        :missing -> replace_index(project, backend)
      end
    end)
  end

  defp create_index_data(%Project{} = project) do
    paths = Paths.for_project(project)
    {entries, manifest_entries} = index_paths(paths.source_paths, paths.beam_paths)

    {entries, Manifest.new(manifest_entries)}
  end

  defp replace_index(%Project{} = project, backend) do
    {entries, manifest} = create_index_data(project)

    replace_index(project, backend, entries, manifest)
  end

  defp refresh_index(%Project{} = project, %Manifest{} = manifest, backend) do
    {entries, paths_to_clear, manifest} = update_index_data(project, manifest, backend)

    with :ok <- apply_index_update(project, backend, entries, paths_to_clear) do
      ManifestStore.commit(project, manifest)
    end
  end

  defp replace_index(%Project{} = project, backend, entries, %Manifest{} = manifest) do
    with :ok <- backend.replace_all(entries),
         :ok <- maybe_sync(project, backend) do
      ManifestStore.commit(project, manifest)
    end
  end

  defp apply_index_update(project, backend, updated_entries, deleted_paths) do
    with :ok <- apply_updated_entries(backend, updated_entries),
         :ok <- apply_deleted_paths(backend, deleted_paths) do
      maybe_sync(project, backend)
    end
  end

  defp apply_updated_entries(backend, updated_entries) do
    updated_entries
    |> Enum.group_by(& &1.path)
    |> Enum.reduce_while(:ok, fn {path, entry_list}, :ok ->
      apply_index_path(backend, path, entry_list)
    end)
  end

  defp apply_deleted_paths(backend, deleted_paths) do
    Enum.reduce_while(deleted_paths, :ok, fn path, :ok ->
      apply_index_path(backend, path, [])
    end)
  end

  defp apply_index_path(backend, path, entries) do
    case replace_backend_path(backend, path, entries) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp replace_backend_path(backend, path, entries) do
    with {:ok, _deleted_ids} <- backend.delete_by_path(path) do
      backend.insert(entries)
    end
  catch
    :exit, {:timeout, _} ->
      Logger.warning("Timeout updating index for path: #{path}")
      :ok
  end

  defp update_index_data(%Project{} = project, %Manifest{} = manifest, backend) do
    paths = Paths.for_project(project)

    plan =
      manifest
      |> Manifest.plan(paths)
      |> include_missing_backend_outputs(manifest, paths, backend)

    {entries, manifest_entries} =
      index_paths(plan.source_paths_to_index, plan.beam_paths_to_index)

    paths_to_clear = Manifest.output_paths_to_clear(manifest, plan, manifest_entries)
    manifest = Manifest.apply_update(manifest, plan, manifest_entries)

    {entries, paths_to_clear, manifest}
  end

  defp include_missing_backend_outputs(
         %Manifest.Plan{} = plan,
         %Manifest{} = manifest,
         paths,
         backend
       ) do
    backend_paths = backend_indexed_paths(backend)
    source_paths = MapSet.new(paths.source_paths)
    beam_paths = MapSet.new(paths.beam_paths)

    {missing_source_paths, missing_beam_paths} =
      manifest
      |> Manifest.entries()
      |> Enum.reduce({[], []}, fn
        %Manifest.Entry{input_path: input_path, output_path: output_path, kind: :source},
        {source_acc, beam_acc}
        when is_binary(output_path) ->
          if MapSet.member?(source_paths, input_path) and
               not MapSet.member?(backend_paths, output_path) do
            {[input_path | source_acc], beam_acc}
          else
            {source_acc, beam_acc}
          end

        %Manifest.Entry{input_path: input_path, output_path: output_path, kind: :beam},
        {source_acc, beam_acc}
        when is_binary(output_path) ->
          if MapSet.member?(beam_paths, input_path) and
               not MapSet.member?(backend_paths, output_path) do
            {source_acc, [input_path | beam_acc]}
          else
            {source_acc, beam_acc}
          end

        _entry, acc ->
          acc
      end)

    %Manifest.Plan{
      plan
      | source_paths_to_index: Enum.uniq(plan.source_paths_to_index ++ missing_source_paths),
        beam_paths_to_index: Enum.uniq(plan.beam_paths_to_index ++ missing_beam_paths)
    }
  end

  defp index_paths(source_paths, beam_paths) do
    {source_entries, source_manifest_entries} = Sources.index(source_paths)
    {beam_entries, beam_manifest_entries} = Beams.index(beam_paths)

    {source_entries ++ beam_entries, source_manifest_entries ++ beam_manifest_entries}
  end

  defp backend_indexed_paths(backend) do
    MapSet.new()
    |> backend.reduce(fn
      %{path: path}, paths when is_binary(path) -> MapSet.put(paths, path)
      _entry, paths -> paths
    end)
  end

  defp with_indexer_context(fun) when is_function(fun, 0) do
    :ok = ApplicationCache.clear()

    ProcessCache.with_cleanup do
      fun.()
    end
  after
    ApplicationCache.clear()
  end

  defp maybe_sync(project, backend) do
    if function_exported?(backend, :sync, 1) do
      backend.sync(project)
    else
      :ok
    end
  end
end
