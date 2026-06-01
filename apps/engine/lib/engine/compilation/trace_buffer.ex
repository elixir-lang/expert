defmodule Engine.Compilation.TraceBuffer do
  @moduledoc """
  Tracks compiler-trace state that must survive until a compile boundary.

  Compiler tracers can significantly slow down compilation, so they should not
  write traced entries to the search index directly. We buffer those entries here
  and update the search store after compilation succeeds.

  Tracers also can't cleanly hold state to determine how to update the indexer
  manifest, so we do that here too.
  """

  use GenServer

  alias Engine.Search.Indexer.Manifest
  alias Engine.Search.Indexer.ManifestStore
  alias Engine.Search.Indexer.Paths
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  defstruct paths: %{}

  defmodule PathState do
    @moduledoc false

    defstruct beam_paths: [],
              defined_modules: MapSet.new(),
              definitions_by_module: %{},
              references: []
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  def clear(path) when is_binary(path) do
    call({:clear, canonical_path(path)}, :ok)
  end

  def add_definitions(path, module, definitions)
      when is_binary(path) and is_atom(module) and is_list(definitions) do
    call({:add_definitions, canonical_path(path), module, definitions}, :ok)
  end

  def add_references(path, references) when is_binary(path) and is_list(references) do
    call({:add_references, canonical_path(path), references}, :ok)
  end

  def add_beam_path(path, beam_path) when is_binary(path) and is_binary(beam_path) do
    call({:add_beam_path, canonical_path(path), canonical_path(beam_path)}, :ok)
  end

  def traced?(path) when is_binary(path) do
    call({:traced?, canonical_path(path)}, false)
  end

  def commit_project(%Project{} = project) do
    call({:commit_project, project}, :ok)
  end

  def commit_project(_project), do: :ok

  def commit_path(project, path, opts \\ [])

  def commit_path(%Project{} = project, path, opts) when is_binary(path) and is_list(opts) do
    call({:commit_path, project, canonical_path(path), opts}, :ok)
  end

  def commit_path(_project, _path, _opts), do: :ok

  def discard_project(%Project{} = _project) do
    call(:discard_project, :ok)
  end

  def discard_project(_project), do: :ok

  def discard(path) when is_binary(path) do
    call({:discard, canonical_path(path)}, :ok)
  end

  @impl true
  def init(%__MODULE__{} = state), do: {:ok, state}

  @impl true
  def handle_call({:clear, path}, _from, %__MODULE__{} = state) do
    {:reply, :ok, put_path_state(state, path, %PathState{})}
  end

  def handle_call({:add_definitions, path, module, definitions}, _from, %__MODULE__{} = state) do
    definitions = Enum.map(definitions, &put_entry_path(&1, path))

    {:reply, :ok, add_definitions_to_path(state, path, module, definitions)}
  end

  def handle_call({:add_references, path, references}, _from, %__MODULE__{} = state) do
    references = Enum.map(references, &put_entry_path(&1, path))

    {:reply, :ok, add_references_to_path(state, path, references)}
  end

  def handle_call({:add_beam_path, path, beam_path}, _from, %__MODULE__{} = state) do
    {:reply, :ok, add_beam_path_to_path(state, path, beam_path)}
  end

  def handle_call({:traced?, path}, _from, %__MODULE__{} = state) do
    {:reply, Map.has_key?(state.paths, path), state}
  end

  def handle_call({:commit_project, project}, _from, %__MODULE__{} = state) do
    {reply, state} = commit_paths(project, Map.keys(state.paths), state, [])
    {:reply, reply, state}
  end

  def handle_call({:commit_path, project, path, opts}, _from, %__MODULE__{} = state) do
    {reply, state} =
      commit_paths(project, [path], state,
        source_always?: true,
        dirty_source?: Keyword.get(opts, :dirty_source?, true)
      )

    {:reply, reply, state}
  end

  def handle_call({:discard, path}, _from, %__MODULE__{} = state) do
    {:reply, :ok, %__MODULE__{state | paths: Map.delete(state.paths, path)}}
  end

  def handle_call(:discard_project, _from, %__MODULE__{} = state) do
    {:reply, :ok, %__MODULE__{state | paths: %{}}}
  end

  defp call(message, default) do
    case Process.whereis(__MODULE__) do
      nil -> default
      pid -> GenServer.call(pid, message)
    end
  end

  defp put_path_state(%__MODULE__{} = state, path, %PathState{} = path_state) do
    %__MODULE__{state | paths: Map.put(state.paths, path, path_state)}
  end

  defp update_path_state(%__MODULE__{} = state, path, update_fun)
       when is_function(update_fun, 1) do
    path_state = Map.get(state.paths, path, %PathState{})
    put_path_state(state, path, update_fun.(path_state))
  end

  defp add_definitions_to_path(%__MODULE__{} = state, path, module, definitions) do
    update_path_state(state, path, fn %PathState{} = path_state ->
      %PathState{
        path_state
        | defined_modules: MapSet.put(path_state.defined_modules, module),
          definitions_by_module: Map.put(path_state.definitions_by_module, module, definitions)
      }
    end)
  end

  defp add_references_to_path(%__MODULE__{} = state, path, references) do
    update_path_state(state, path, fn %PathState{} = path_state ->
      %PathState{path_state | references: Enum.reverse(references, path_state.references)}
    end)
  end

  defp add_beam_path_to_path(%__MODULE__{} = state, path, beam_path) do
    update_path_state(state, path, fn %PathState{} = path_state ->
      %PathState{path_state | beam_paths: [beam_path | path_state.beam_paths]}
    end)
  end

  defp commit_paths(project, candidate_paths, %__MODULE__{} = state, opts) do
    paths = Enum.filter(candidate_paths, &Map.has_key?(state.paths, &1))

    case paths do
      [] ->
        {:ok, state}

      [_ | _] ->
        reply =
          with :ok <- commit_search(project, paths, state.paths) do
            commit_manifest(project, paths, state.paths, opts)
          end

        {reply, %__MODULE__{state | paths: Map.drop(state.paths, paths)}}
    end
  end

  defp commit_search(project, paths, path_states) do
    trace_updates =
      Enum.map(paths, fn path ->
        path_state = Map.fetch!(path_states, path)
        {path, modules(path_state), entries(path_state)}
      end)

    Engine.ManagerApi.search_store_commit_traces(project, trace_updates)
  end

  defp commit_manifest(project, paths, path_states, opts) do
    trace_sources =
      Enum.map(paths, fn path ->
        %PathState{beam_paths: beam_paths} = Map.fetch!(path_states, path)
        {path, beam_paths}
      end)

    commit_trace_manifest(project, trace_sources, opts)
  end

  defp commit_trace_manifest(%Project{} = project, trace_sources, opts)
       when is_list(trace_sources) do
    source_always? = Keyword.get(opts, :source_always?, false)
    dirty_source? = Keyword.get(opts, :dirty_source?, false)

    case manifest_entries_by_output(project, trace_sources, source_always?, dirty_source?) do
      outputs when map_size(outputs) == 0 ->
        :ok

      outputs ->
        ManifestStore.update(project, fn manifest ->
          Manifest.replace_outputs(manifest, outputs)
        end)
    end
  end

  defp manifest_entries(source_path, beam_paths)
       when is_binary(source_path) and is_list(beam_paths) do
    beam_paths
    |> Enum.reverse()
    |> Enum.uniq()
    |> Enum.flat_map(&manifest_entry_for_beam(source_path, &1))
  end

  defp manifest_entries_by_output(
         %Project{} = project,
         trace_sources,
         source_always?,
         dirty_source?
       ) do
    source_scope = Paths.source_scope(project)

    trace_sources
    |> Enum.flat_map(fn {source_path, beam_paths} ->
      entries = manifest_entries(source_path, beam_paths)

      entries ++
        source_manifest_entries(source_path, entries, source_scope, source_always?, dirty_source?)
    end)
    |> Enum.group_by(&Manifest.output_path/1)
    |> Map.reject(fn {output_path, _entries} -> is_nil(output_path) end)
  end

  defp source_manifest_entries(path, trace_entries, source_scope, source_always?, dirty_source?) do
    manifested_paths = manifested_paths(trace_entries)

    if source_manifest_entry_needed?(path, source_scope, manifested_paths, source_always?) do
      case source_manifest_entry(path, dirty_source?) do
        {:ok, entry} -> [entry]
        :error -> []
      end
    else
      []
    end
  end

  defp manifested_paths(entries) do
    entries
    |> Enum.flat_map(&Manifest.paths/1)
    |> MapSet.new()
  end

  defp source_manifest_entry_needed?(path, source_scope, manifested_paths, source_always?) do
    (source_always? or project_source?(path, source_scope)) and
      not MapSet.member?(manifested_paths, path)
  end

  defp project_source?(path, %{source_roots: source_roots, excluded_roots: excluded_roots}) do
    Path.extname(path) == ".ex" and contained_in_any?(path, source_roots) and
      not contained_in_any?(path, excluded_roots)
  end

  defp contained_in_any?(path, roots) do
    Enum.any?(roots, &Forge.Path.contains?(path, &1))
  end

  defp source_manifest_entry(path, true), do: Manifest.Entry.dirty_source(path)
  defp source_manifest_entry(path, false), do: Manifest.Entry.source(path)

  defp manifest_entry_for_beam(source_path, beam_path) do
    with {:ok, %File.Stat{} = beam_stat} <- File.stat(beam_path),
         {:ok, %File.Stat{} = source_stat} <- File.stat(source_path),
         {:ok, manifest_entry} <-
           Manifest.Entry.beam(beam_path, source_path, beam_stat, {:ok, source_stat}) do
      [manifest_entry]
    else
      _ -> []
    end
  end

  defp modules(%PathState{defined_modules: defined_modules}) do
    MapSet.to_list(defined_modules)
  end

  defp entries(%PathState{definitions_by_module: definitions_by_module, references: references}) do
    definitions_by_module
    |> Map.values()
    |> List.flatten()
    |> Enum.concat(Enum.reverse(references))
  end

  defp put_entry_path(%Entry{} = entry, path), do: %Entry{entry | path: path}

  defp canonical_path(path) when is_binary(path), do: Path.expand(path)
end
