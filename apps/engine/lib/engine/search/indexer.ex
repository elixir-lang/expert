defmodule Engine.Search.Indexer do
  alias Engine.ApplicationCache
  alias Engine.Progress
  alias Engine.Search.Indexer.Beams
  alias Engine.Search.Indexer.Manifest
  alias Engine.Search.Indexer.ManifestStore
  alias Engine.Search.Indexer.Paths
  alias Engine.Search.Indexer.Sources
  alias Forge.ProcessCache
  alias Forge.Project

  require ProcessCache

  def create_index(%Project{} = project) do
    with_indexer_context(fn ->
      {entries, manifest} = create_index_data(project)

      {:ok, entries, manifest}
    end)
  end

  def commit_manifest(%Project{} = project, %Manifest{} = manifest) do
    ManifestStore.commit(project, manifest)
  end

  def update_index(%Project{} = project, path_to_ids) when is_map(path_to_ids) do
    with_indexer_context(fn ->
      case ManifestStore.load(project) do
        {:ok, %Manifest{} = manifest} -> refresh_index(project, manifest, path_to_ids)
        :missing -> replace_index(project, path_to_ids)
      end
    end)
  end

  defp create_index_data(%Project{} = project) do
    paths = Paths.for_project(project)
    planning_paths = planning_paths(project, paths)

    {entries, manifest_entries} =
      index_paths(planning_paths.source_paths, planning_paths.beam_paths,
        project_source_paths: paths.source_paths
      )

    {entries, Manifest.new(manifest_entries)}
  end

  defp replace_index(%Project{} = project, path_to_ids) do
    {entries, manifest} = create_index_data(project)
    paths_to_clear = stored_paths_to_clear(path_to_ids, entries)

    {:ok, entries, paths_to_clear, manifest}
  end

  defp refresh_index(%Project{} = project, %Manifest{} = manifest, path_to_ids) do
    {entries, paths_to_clear, manifest} = update_index_data(project, manifest, path_to_ids)

    {:ok, entries, paths_to_clear, manifest}
  end

  defp update_index_data(%Project{} = project, %Manifest{} = manifest, path_to_ids) do
    paths = Paths.for_project(project)
    planning_paths = planning_paths(project, paths, manifest)
    source_manifest_output_paths = source_manifest_output_paths(manifest)

    plan =
      manifest
      |> Manifest.plan(planning_paths)
      |> include_missing_stored_outputs(manifest, planning_paths, path_to_ids)
      |> exclude_trace_covered_source_paths(source_manifest_output_paths)

    {entries, manifest_entries, plan} =
      index_plan(plan, manifest, paths,
        project_source_paths: paths.source_paths,
        trace_covered_paths: source_manifest_output_paths
      )

    paths_to_clear = Manifest.output_paths_to_clear(manifest, plan, manifest_entries)
    manifest = Manifest.apply_update(manifest, plan, manifest_entries)

    {entries, paths_to_clear, manifest}
  end

  defp index_plan(%Manifest.Plan{} = plan, %Manifest{} = manifest, %Paths{} = paths, opts) do
    {entries, manifest_entries, beam_paths_to_index} =
      index_inputs(plan.source_paths_to_index, plan.beam_paths_to_index, fn beam_paths ->
        index_beam_plan(
          %Manifest.Plan{plan | beam_paths_to_index: beam_paths},
          manifest,
          paths,
          opts
        )
      end)

    plan = %Manifest.Plan{plan | beam_paths_to_index: beam_paths_to_index}

    {entries, manifest_entries, plan}
  end

  defp exclude_trace_covered_source_paths(%Manifest.Plan{} = plan, trace_covered_paths) do
    %Manifest.Plan{
      plan
      | source_paths_to_index:
          Enum.reject(plan.source_paths_to_index, &MapSet.member?(trace_covered_paths, &1))
    }
  end

  defp index_inputs(source_paths, beam_paths, index_beams_fun)
       when is_list(source_paths) and is_list(beam_paths) and is_function(index_beams_fun, 1) do
    Progress.with_progress("Indexing search inputs", fn _token ->
      {elapsed_ms, result} =
        timed(fn ->
          {source_elapsed_ms, {source_entries, source_manifest_entries}} =
            timed(fn -> Sources.index(source_paths) end)

          {beam_elapsed_ms, {beam_entries, beam_manifest_entries, indexed_beam_paths}} =
            timed(fn -> index_beams_fun.(beam_paths) end)

          metrics = %{
            source_count: length(source_paths),
            source_elapsed_ms: source_elapsed_ms,
            beam_count: length(indexed_beam_paths),
            beam_elapsed_ms: beam_elapsed_ms
          }

          entries = source_entries ++ beam_entries
          manifest_entries = source_manifest_entries ++ beam_manifest_entries

          {entries, manifest_entries, indexed_beam_paths, metrics}
        end)

      {entries, manifest_entries, indexed_beam_paths, metrics} = result
      Progress.log_info(index_detail_message(metrics))

      {:done, {entries, manifest_entries, indexed_beam_paths},
       indexed_files_message(metrics, elapsed_ms)}
    end)
  end

  defp index_beam_paths(beam_paths, opts) do
    {entries, manifest_entries} = Beams.index(beam_paths, opts)

    {entries, manifest_entries, beam_paths}
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
  defp index_beam_plan(%Manifest.Plan{beam_paths_to_index: []}, _manifest, _paths, _opts) do
    {[], [], []}
  end

  defp index_beam_plan(%Manifest.Plan{} = plan, %Manifest{} = manifest, %Paths{} = paths, opts) do
    {entries, manifest_entries} = Beams.index(plan.beam_paths_to_index, opts)
    sibling_paths = beam_sibling_paths(plan, manifest, paths, manifest_entries)

    case sibling_paths do
      [] ->
        {entries, manifest_entries, plan.beam_paths_to_index}

      [_ | _] ->
        {sibling_entries, sibling_manifest_entries} = Beams.index(sibling_paths, opts)

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

  defp include_missing_stored_outputs(
         %Manifest.Plan{} = plan,
         %Manifest{} = manifest,
         paths,
         path_to_ids
       ) do
    stored_paths = stored_paths(path_to_ids)
    source_paths = MapSet.new(paths.source_paths)
    beam_paths = MapSet.new(paths.beam_paths)

    {missing_source_paths, missing_beam_paths} =
      manifest
      |> Manifest.entries()
      |> Enum.reduce({[], []}, fn
        %Manifest.Entry{input_path: input_path, output_path: output_path, kind: :source},
        {source_acc, beam_acc}
        when is_binary(output_path) ->
          if missing_stored_output?(input_path, output_path, source_paths, stored_paths) do
            {[input_path | source_acc], beam_acc}
          else
            {source_acc, beam_acc}
          end

        %Manifest.Entry{input_path: input_path, output_path: output_path, kind: :beam},
        {source_acc, beam_acc}
        when is_binary(output_path) ->
          if missing_stored_output?(input_path, output_path, beam_paths, stored_paths) do
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

  defp missing_stored_output?(input_path, output_path, current_input_paths, stored_paths) do
    MapSet.member?(current_input_paths, input_path) and
      not MapSet.member?(stored_paths, output_path)
  end

  defp index_paths(source_paths, beam_paths, opts) do
    {entries, manifest_entries, _indexed_beam_paths} =
      index_inputs(source_paths, beam_paths, &index_beam_paths(&1, opts))

    {entries, manifest_entries}
  end

  defp planning_paths(%Project{kind: :mix}, %Paths{} = paths) do
    %Paths{paths | source_paths: Enum.filter(paths.source_paths, &script_source?/1)}
  end

  defp planning_paths(%Project{}, %Paths{} = paths), do: paths

  defp planning_paths(%Project{} = project, %Paths{} = paths, %Manifest{} = manifest) do
    planned_paths = planning_paths(project, paths)

    %Paths{
      planned_paths
      | source_paths:
          Enum.uniq(
            planned_paths.source_paths ++ source_manifest_paths(paths.source_paths, manifest)
          )
    }
  end

  defp source_manifest_paths(source_paths, %Manifest{} = manifest) do
    source_paths = MapSet.new(source_paths)

    manifest
    |> Manifest.entries()
    |> Enum.flat_map(fn
      %Manifest.Entry{kind: :source, input_path: input_path}
      when is_binary(input_path) ->
        if MapSet.member?(source_paths, input_path), do: [input_path], else: []

      _entry ->
        []
    end)
  end

  defp source_manifest_output_paths(%Manifest{} = manifest) do
    manifest
    |> Manifest.entries()
    |> Enum.flat_map(fn
      %Manifest.Entry{kind: :source} = entry ->
        if trace_covered_source_entry?(entry),
          do: [entry.output_path || entry.input_path],
          else: []

      _entry ->
        []
    end)
    |> Enum.filter(&(Path.extname(&1) == ".ex"))
    |> MapSet.new()
  end

  defp trace_covered_source_entry?(%Manifest.Entry{input_path: path, mtime: mtime, size: size})
       when is_binary(path) do
    Path.extname(path) == ".ex" and not is_nil(mtime) and not is_nil(size)
  end

  defp trace_covered_source_entry?(%Manifest.Entry{}), do: false

  defp script_source?(path), do: Path.extname(path) == ".exs"

  defp stored_paths_to_clear(path_to_ids, entries) do
    indexed_paths = MapSet.new(entries, & &1.path)

    path_to_ids
    |> stored_paths()
    |> MapSet.difference(indexed_paths)
    |> Enum.to_list()
  end

  defp stored_paths(path_to_ids) when is_map(path_to_ids) do
    path_to_ids
    |> Map.keys()
    |> MapSet.new()
  end

  defp index_detail_message(%{
         source_count: source_count,
         source_elapsed_ms: source_elapsed_ms,
         beam_count: beam_count,
         beam_elapsed_ms: beam_elapsed_ms
       }) do
    "Indexed search inputs: #{format_source_file_count(source_count)} in #{format_duration(source_elapsed_ms)}; " <>
      "#{format_beam_file_count(beam_count)} in #{format_duration(beam_elapsed_ms)}"
  end

  defp indexed_files_message(%{source_count: source_count, beam_count: beam_count}, elapsed_ms) do
    total = source_count + beam_count

    "Indexed #{format_file_count(total)} in #{format_duration(elapsed_ms)}"
  end

  defp format_source_file_count(count), do: "#{count} source #{plural(count, "file", "files")}"
  defp format_beam_file_count(count), do: "#{count} BEAM #{plural(count, "file", "files")}"
  defp format_file_count(count), do: "#{count} #{plural(count, "file", "files")}"

  defp plural(1, singular, _plural), do: singular
  defp plural(_count, _singular, plural), do: plural

  defp with_indexer_context(fun) when is_function(fun, 0) do
    :ok = ApplicationCache.clear()

    ProcessCache.with_cleanup do
      fun.()
    end
  after
    ApplicationCache.clear()
  end

  defp timed(fun) when is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - start, result}
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
