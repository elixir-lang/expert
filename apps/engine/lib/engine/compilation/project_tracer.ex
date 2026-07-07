defmodule Engine.Compilation.ProjectTracer do
  import Forge.EngineApi.Messages

  alias Engine.Compilation.TraceBuffer
  alias Engine.Compilation.TraceProgress
  alias Engine.Search.Indexer.Beams
  alias Engine.Search.Indexer.Metadata
  alias Engine.Search.Indexer.Paths
  alias Engine.Search.Subject
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Project
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Indexer.Source.Block

  @source_scope_key {__MODULE__, :source_scope}

  def with_project(%Project{} = project, fun) when is_function(fun, 0) do
    with_project(project, [], fun)
  end

  def with_project(%Project{} = project, opts, fun) when is_list(opts) and is_function(fun, 0) do
    previous_source_scope = :persistent_term.get(@source_scope_key, :unset)
    :persistent_term.put(@source_scope_key, source_scope(project, opts))

    try do
      fun.()
    after
      restore_source_scope(previous_source_scope)
    end
  end

  def trace(:start, %Macro.Env{file: file, module: nil}) do
    trace_project_source(file, &TraceBuffer.clear/1)
  end

  def trace({:alias, metadata, module, _as, _opts}, %Macro.Env{file: file}) do
    trace_project_source(file, &module_reference(&1, module, metadata))
  end

  def trace({:alias_reference, metadata, module}, %Macro.Env{file: file}) do
    trace_project_source(file, &module_reference(&1, module, metadata))
  end

  def trace({:struct_expansion, metadata, module, _keys}, %Macro.Env{file: file}) do
    trace_project_source(file, &struct_reference(&1, module, metadata))
  end

  def trace({type, metadata, module, name, arity}, %Macro.Env{file: file})
      when type in [:remote_function, :remote_macro, :imported_function, :imported_macro] do
    if not excluded_reference?(module, name) do
      trace_project_source(
        file,
        &function_reference(&1, module, name, arity, metadata)
      )
    end

    :ok
  end

  def trace({type, metadata, name, arity}, %Macro.Env{file: file, module: module})
      when type in [:local_function, :local_macro] and is_atom(module) do
    trace_project_source(file, &function_reference(&1, module, name, arity, metadata))
  end

  def trace({:on_module, module_binary, _filename}, %Macro.Env{} = env) do
    file = canonical_path(env.file)

    TraceProgress.report(file)
    maybe_broadcast_exports(module_binary, file)

    if project_source?(file) do
      maybe_buffer_definitions(module_binary, file, env.module)
    end

    :ok
  end

  def trace(_event, _env) do
    :ok
  end

  defp maybe_broadcast_exports(module_binary, file) do
    case Beams.extract_exports_from_binary(module_binary) do
      {:ok, exports} -> Engine.broadcast(module_updated_message(exports, file))
      :error -> :ok
    end
  end

  defp module_updated_message(exports, file) do
    module_updated(
      file: file,
      functions: exports.functions,
      macros: exports.macros,
      name: exports.module,
      struct: exports.struct
    )
  end

  defp maybe_buffer_definitions(module_binary, file, module) do
    case Beams.extract_definitions_from_binary(module_binary,
           include_private?: true,
           source_path: file
         ) do
      {:ok, definitions} ->
        TraceBuffer.add_definitions(file, module, definitions)
        maybe_buffer_beam_path(file, module)

      _ ->
        :ok
    end
  end

  defp maybe_buffer_beam_path(file, module) do
    with true <- buffer_beam_paths?(),
         beam_path when is_binary(beam_path) <- beam_path(module) do
      TraceBuffer.add_beam_path(file, beam_path)
    else
      _ -> :ok
    end
  end

  defp beam_path(module) when is_atom(module) do
    if Engine.Mix.loaded?() do
      Path.join(Mix.Project.compile_path(), "#{Atom.to_string(module)}.beam")
    end
  rescue
    _ -> nil
  end

  defp excluded_reference?(_module, :@), do: true

  defp excluded_reference?(Kernel, name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.starts_with?("def")
  end

  defp excluded_reference?(_module, _name), do: false

  defp function_reference(path, module, name, arity, metadata) do
    insert_reference(
      path,
      metadata,
      Atom.to_string(name),
      Subject.mfa(module, name, arity),
      {:function, :usage},
      module
    )
  end

  defp module_reference(path, module, metadata) do
    insert_reference(path, metadata, module, Subject.module(module), :module, module)
  end

  defp struct_reference(path, module, metadata) do
    insert_reference(path, metadata, module, Subject.module(module), :struct, module)
  end

  defp insert_reference(path, metadata, identifier, subject, type, app_module) do
    case metadata_range(metadata, identifier) do
      {:ok, range} ->
        entry =
          path
          |> Entry.reference(
            Block.root(),
            subject,
            type,
            range,
            Engine.ApplicationCache.application(app_module)
          )
          |> Entry.put_metadata(%{trace_identifier: identifier})

        TraceBuffer.add_references(path, [entry])

      :error ->
        :ok
    end
  end

  defp metadata_range(metadata, identifier) when is_list(metadata) do
    case Metadata.position(metadata) do
      {line, column} when is_integer(line) and is_integer(column) ->
        {:ok, range(line, column, identifier_length(identifier))}

      _ ->
        :error
    end
  end

  defp metadata_range(_metadata, _identifier), do: :error

  defp identifier_length(identifier) when is_atom(identifier) do
    identifier
    |> Macro.to_string()
    |> String.replace_prefix("Elixir.", "")
    |> positive_string_length()
  end

  defp identifier_length(identifier) do
    identifier
    |> to_string()
    |> positive_string_length()
  end

  defp positive_string_length(string) do
    string
    |> String.length()
    |> max(1)
  end

  defp range(line, column, length) do
    Range.new(
      position(line, column),
      position(line, column + length)
    )
  end

  defp position(line, column) do
    %Position{line: line, character: column, starting_index: 1}
  end

  defp canonical_path(path) when is_binary(path), do: path |> Path.expand() |> Forge.Path.native()
  defp canonical_path(path), do: path

  defp trace_project_source(file, fun) when is_function(fun, 1) do
    file = canonical_path(file)

    if project_source?(file), do: fun.(file)

    :ok
  end

  defp project_source?(path) when is_binary(path) do
    Path.extname(path) == ".ex" and project_source_path?(path)
  end

  defp project_source?(_path), do: false

  defp project_source_path?(path) do
    case :persistent_term.get(@source_scope_key, nil) do
      %{source_roots: source_roots, excluded_roots: excluded_roots} ->
        contained_in_any?(path, source_roots) and not contained_in_any?(path, excluded_roots)

      _ ->
        simple_project_source_path?(path)
    end
  end

  defp simple_project_source_path?(path) do
    with %Project{} = project <- Engine.get_project(),
         root_path when is_binary(root_path) <- Project.root_path(project) do
      Forge.Path.contains?(path, root_path) and
        not contained_in_any?(path, simple_excluded_roots(project, root_path))
    else
      _ -> false
    end
  end

  defp simple_excluded_roots(%Project{} = project, root_path) do
    [
      Project.workspace_path(project),
      Path.join(root_path, "_build"),
      Path.join(root_path, "deps")
    ]
  end

  defp contained_in_any?(path, roots) do
    Enum.any?(roots, &Forge.Path.contains?(path, &1))
  end

  defp source_scope(%Project{} = project, opts) do
    project
    |> Paths.source_scope()
    |> Map.put(:buffer_beam_paths?, Keyword.get(opts, :buffer_beam_paths?, true))
  end

  defp buffer_beam_paths? do
    case :persistent_term.get(@source_scope_key, nil) do
      %{buffer_beam_paths?: buffer_beam_paths?} -> buffer_beam_paths?
      _ -> true
    end
  end

  defp restore_source_scope(:unset), do: :persistent_term.erase(@source_scope_key)
  defp restore_source_scope(scope), do: :persistent_term.put(@source_scope_key, scope)
end
