defmodule Engine.Search.Indexer.Sources do
  alias Engine.Progress
  alias Engine.Search.Indexer.Manifest
  alias Engine.Search.Indexer.Source

  def index(paths) when is_list(paths) do
    paths
    |> map_paths("Indexing source code", "Indexing", &index_path/1)
    |> entries_and_manifest_entries()
  end

  defp index_path(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, [_ | _] = entries} <- Source.index(path, contents),
         true <- has_search_entries?(entries),
         {:ok, manifest_entry} <- Manifest.Entry.source(path) do
      [{entries, manifest_entry}]
    else
      _ -> []
    end
  end

  defp has_search_entries?(entries) do
    Enum.any?(entries, fn entry -> entry.subtype != :block_structure end)
  end

  defp entries_and_manifest_entries(results) do
    entries = Enum.flat_map(results, fn {entries, _manifest_entry} -> entries end)
    manifest_entries = Enum.map(results, fn {_entries, manifest_entry} -> manifest_entry end)

    {entries, manifest_entries}
  end

  defp map_paths([], _title, _message, _processor), do: []

  defp map_paths(paths, title, message, processor) do
    Progress.with_tracked_progress(title, length(paths), fn report ->
      start_time = System.monotonic_time(:millisecond)

      results =
        paths
        |> Task.async_stream(
          fn path ->
            report.(message: message, add: 1)
            processor.(path)
          end,
          timeout: :infinity
        )
        |> Enum.flat_map(&task_result!/1)

      elapsed = System.monotonic_time(:millisecond) - start_time
      {:done, results, "Completed in #{format_duration(elapsed)}"}
    end)
  end

  defp task_result!({:ok, items}), do: items

  defp task_result!({:exit, reason}),
    do: raise("Indexing task failed: #{Exception.format_exit(reason)}")

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
