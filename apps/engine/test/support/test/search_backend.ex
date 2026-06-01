defmodule Engine.Test.SearchBackend do
  alias Forge.Search.Indexer.Entry

  def new(_project), do: {:ok, :new}

  def prepare(_backend_result) do
    if entries() == [] do
      {:ok, :empty}
    else
      {:ok, :stale}
    end
  end

  def set_entries(entries) when is_list(entries) do
    :persistent_term.put({__MODULE__, :entries}, entries)
  end

  def entries do
    :persistent_term.get({__MODULE__, :entries}, [])
  end

  def path_to_ids do
    Enum.reduce(entries(), %{}, fn
      %Entry{path: path} = entry, path_to_ids when is_integer(entry.id) ->
        Map.update(path_to_ids, path, entry.id, &max(&1, entry.id))

      _entry, path_to_ids ->
        path_to_ids
    end)
  end

  def sync(_project), do: :ok

  def replace_all(_project, new_entries) when is_list(new_entries) do
    set_entries(new_entries)
    :ok
  end

  def delete_by_path(_project, path) do
    {deleted_entries, kept_entries} =
      entries()
      |> Enum.split_with(&(&1.path == path))

    set_entries(kept_entries)

    {:ok, Enum.flat_map(deleted_entries, &List.wrap(&1.id))}
  end

  def insert(_project, new_entries) when is_list(new_entries) do
    set_entries(entries() ++ new_entries)
    :ok
  end

  def apply_index_update(_project, updated_entries, paths_to_clear) do
    paths_to_clear =
      updated_entries
      |> Enum.map(& &1.path)
      |> Enum.reject(&is_nil/1)
      |> Enum.concat(paths_to_clear)
      |> MapSet.new()

    {deleted_entries, kept_entries} =
      Enum.split_with(entries(), &MapSet.member?(paths_to_clear, &1.path))

    set_entries(kept_entries ++ updated_entries)

    {:ok, Enum.flat_map(deleted_entries, &List.wrap(&1.id))}
  end

  def commit_traces(trace_updates) do
    trace_updates =
      Enum.map(trace_updates, fn {path, modules, new_entries} ->
        entries = Enum.map(new_entries, fn %Entry{} = entry -> %Entry{entry | path: path} end)
        {path, Enum.uniq(modules), entries}
      end)

    traced_paths = MapSet.new(trace_updates, fn {path, _modules, _entries} -> path end)

    modules =
      trace_updates |> Enum.flat_map(fn {_path, modules, _entries} -> modules end) |> Enum.uniq()

    module_atoms = MapSet.new(modules)
    module_by_name = Map.new(modules, &{Forge.Formats.module(&1), &1})

    kept_entries =
      Enum.reject(entries(), fn %Entry{} = entry ->
        MapSet.member?(traced_paths, entry.path) or
          exact_module_definition?(entry, module_atoms, module_by_name)
      end)

    new_entries =
      Enum.flat_map(trace_updates, fn {path, _modules, entries} ->
        ensure_block_structure(path, entries)
      end)

    set_entries(kept_entries ++ new_entries)
  end

  def reduce(_project, accumulator, reducer_fun) do
    Enum.reduce(entries(), accumulator, fn
      %Entry{} = entry, acc -> reducer_fun.(entry, acc)
      _entry, acc -> acc
    end)
  end

  def find_by_subject(_project, subject, type, subtype) do
    Enum.filter(entries(), fn entry ->
      subject_matches?(entry.subject, subject) and matches?(entry, type, subtype)
    end)
  end

  def find_by_prefix(_project, prefix, type, subtype) do
    Enum.filter(entries(), fn entry ->
      String.starts_with?(to_string(entry.subject), prefix) and matches?(entry, type, subtype)
    end)
  end

  def find_by_ids(_project, ids, type, subtype) do
    ids = MapSet.new(ids)
    Enum.filter(entries(), &(MapSet.member?(ids, &1.id) and matches?(&1, type, subtype)))
  end

  def siblings(_project, _entry), do: []
  def parent(_project, _entry), do: nil
  def structure_for_path(_project, _path), do: :error
  def drop(_project), do: set_entries([])
  def destroy(_project), do: :ok

  defp subject_matches?(_entry_subject, :_), do: true
  defp subject_matches?(subject, subject), do: true
  defp subject_matches?(subject, query), do: to_string(subject) == to_string(query)

  defp matches?(%Entry{} = entry, type, subtype) do
    (type == :_ or entry.type == type) and (subtype == :_ or entry.subtype == subtype)
  end

  defp exact_module_definition?(
         %Entry{subtype: :definition, subject: subject},
         module_atoms,
         module_by_name
       ) do
    cond do
      is_atom(subject) -> MapSet.member?(module_atoms, subject)
      is_binary(subject) -> match?({:ok, _module}, exact_function_module(subject, module_by_name))
      true -> false
    end
  end

  defp exact_module_definition?(%Entry{}, _module_atoms, _module_by_name), do: false

  defp exact_function_module(subject, module_by_name) do
    case Regex.run(~r/^(.+)\.[^.\/]+\/\d+$/, subject) do
      [_, module_name] -> Map.fetch(module_by_name, module_name)
      _ -> :error
    end
  end

  defp ensure_block_structure(path, entries) do
    if Enum.any?(entries, &(&1.type == :metadata and &1.subtype == :block_structure)) do
      entries
    else
      [Entry.block_structure(path, %{root: %{}}) | entries]
    end
  end
end
