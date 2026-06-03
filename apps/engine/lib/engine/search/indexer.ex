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

    {entries, manifest_entries, plan} = index_plan(plan, manifest, paths)

    paths_to_clear = Manifest.output_paths_to_clear(manifest, plan, manifest_entries)
    manifest = Manifest.apply_update(manifest, plan, manifest_entries)

    {entries, paths_to_clear, manifest}
  end

  defp index_plan(%Manifest.Plan{} = plan, %Manifest{} = manifest, %Paths{} = paths) do
    {source_entries, source_manifest_entries} = Sources.index(plan.source_paths_to_index)

    {beam_entries, beam_manifest_entries, beam_paths_to_index} =
      index_beam_plan(plan, manifest, paths)

    plan = %Manifest.Plan{plan | beam_paths_to_index: beam_paths_to_index}

    {source_entries ++ beam_entries, source_manifest_entries ++ beam_manifest_entries, plan}
  end

  # Search entries use the source file path as their `path`. They do not carry the
  # BEAM file path because entries model searchable source symbols. The BEAM input
  # path is incremental-indexing state, tracked by the manifest.
  #
  # A single source file can produce multiple BEAM files. For example:
  #
  #   defmodule Parent do
  #     defmodule Child do
  #     end
  #   end
  #
  # produces both `Elixir.Parent.beam` and `Elixir.Parent.Child.beam`. Entries from
  # both BEAM files are stored under the same source path.
  #
  # Updating the index for a source path is a full replacement: delete all existing
  # entries for that source path, then insert the entries from this indexing pass.
  # If we index only a newly discovered child BEAM, the replacement set contains
  # only child entries, so existing parent entries for the same source path would be
  # deleted.
  #
  # Supporting narrower replacement would require storing BEAM-origin paths in
  # the search store which would potentially increase the index size by a lot
  # in large codebases. As a compromise, this keeps the existing source-path
  # replacement model and only reindexes known BEAMs that share a source path
  # with the new BEAM.
  defp index_beam_plan(%Manifest.Plan{beam_paths_to_index: []}, _manifest, _paths) do
    {[], [], []}
  end

  defp index_beam_plan(%Manifest.Plan{} = plan, %Manifest{} = manifest, %Paths{} = paths) do
    {entries, manifest_entries} = Beams.index(plan.beam_paths_to_index)
    sibling_paths = beam_sibling_paths(plan, manifest, paths, manifest_entries)

    case sibling_paths do
      [] ->
        {entries, manifest_entries, plan.beam_paths_to_index}

      [_ | _] ->
        {sibling_entries, sibling_manifest_entries} = Beams.index(sibling_paths)

        {entries ++ sibling_entries, manifest_entries ++ sibling_manifest_entries,
         Enum.uniq(plan.beam_paths_to_index ++ sibling_paths)}
    end
  end

  defp beam_sibling_paths(
         %Manifest.Plan{} = plan,
         %Manifest{} = manifest,
         %Paths{} = paths,
         manifest_entries
       ) do
    new_beam_paths =
      plan.beam_paths_to_index
      |> Enum.filter(&(Manifest.fetch(manifest, &1) == :error))
      |> MapSet.new()

    output_paths =
      for %Manifest.Entry{kind: :beam, input_path: input_path, output_path: output_path} <-
            manifest_entries,
          is_binary(output_path),
          MapSet.member?(new_beam_paths, input_path),
          into: MapSet.new() do
        output_path
      end

    current_beam_paths = MapSet.new(paths.beam_paths)
    planned_beam_paths = MapSet.new(plan.beam_paths_to_index)

    for %Manifest.Entry{kind: :beam, input_path: input_path, output_path: output_path} <-
          Manifest.entries(manifest),
        is_binary(output_path),
        MapSet.member?(output_paths, output_path),
        MapSet.member?(current_beam_paths, input_path),
        not MapSet.member?(planned_beam_paths, input_path) do
      input_path
    end
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
