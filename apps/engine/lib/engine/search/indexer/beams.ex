defmodule Engine.Search.Indexer.Beams do
  alias Engine.ApplicationCache
  alias Engine.Progress
  alias Engine.Search.Indexer.Extractors
  alias Engine.Search.Indexer.Manifest
  alias Engine.Search.Indexer.Source
  alias Engine.Search.Subject
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Indexer.Source.Block

  @beam_index_concurrency 16
  @beam_index_chunk_bytes 128 * 1024
  @source_reference_extractors [
    Extractors.Module,
    Extractors.FunctionReference,
    Extractors.StructReference
  ]

  def index(paths, opts \\ []) when is_list(paths) do
    {beams, total_bytes} = stat_beams(paths)
    opts = index_opts(opts)

    beams
    |> index_beam_chunks(total_bytes)
    |> entries_and_manifest_entries(opts)
  end

  def extract_definitions_from_binary(beam, opts \\ []) when is_binary(beam) do
    with {:ok, metadata} <- extract_metadata_from_binary(beam) do
      metadata =
        metadata
        |> normalize_metadata_source_path()
        |> maybe_put_source_path(Keyword.get(opts, :source_path))

      source_path = Map.get(metadata, :file)
      entries = metadata_entries(metadata, source_lines(metadata), opts)
      {:ok, with_source_document_ranges(source_path, entries)}
    end
  end

  def extract_exports_from_binary(beam) when is_binary(beam) do
    with {:ok, metadata} <- extract_metadata_from_binary(beam) do
      {:ok,
       %{
         functions: exported_definitions(metadata, :def),
         macros: exported_definitions(metadata, :defmacro),
         module: Map.fetch!(metadata, :module),
         struct: struct_fields(metadata)
       }}
    end
  end

  defp stat_beams(paths) do
    Enum.reduce(paths, {[], 0}, fn path, {beams, total_bytes} ->
      case File.stat(path) do
        {:ok, %File.Stat{} = stat} ->
          {[{path, stat} | beams], total_bytes + stat.size}

        _ ->
          {beams, total_bytes}
      end
    end)
  end

  defp index_beam_chunks([], _total_bytes), do: []

  defp index_beam_chunks(beams, total_bytes) do
    Progress.with_tracked_progress("Indexing BEAM metadata", total_bytes, fn report ->
      start_time = System.monotonic_time(:millisecond)

      results =
        beams
        |> beam_chunks()
        |> Task.async_stream(&index_beam_chunk(&1, report),
          max_concurrency: @beam_index_concurrency,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.flat_map(&task_result!/1)

      elapsed = System.monotonic_time(:millisecond) - start_time

      message =
        "Checked #{length(beams)} BEAM #{file_label(beams)} in #{format_duration(elapsed)}"

      {:done, results, message}
    end)
  end

  defp beam_chunks(beams) do
    {chunks, current_chunk} =
      Enum.reduce(beams, {[], {0, []}}, fn beam, {chunks, {chunk_bytes, chunk_beams}} ->
        chunk_bytes = chunk_bytes + beam_size(beam)
        chunk_beams = [beam | chunk_beams]

        if chunk_bytes >= @beam_index_chunk_bytes do
          {[{chunk_bytes, chunk_beams} | chunks], {0, []}}
        else
          {chunks, {chunk_bytes, chunk_beams}}
        end
      end)

    case current_chunk do
      {0, []} -> chunks
      {_chunk_bytes, [_ | _]} = chunk -> [chunk | chunks]
    end
  end

  defp beam_size({_path, %File.Stat{size: size}}), do: size

  defp index_beam_chunk({chunk_bytes, beams}, report) do
    report.(message: "Indexing dependencies", add: chunk_bytes)
    Enum.flat_map(beams, &metadata_from_beam/1)
  end

  defp entries_and_manifest_entries(results, opts) do
    results = Enum.reject(results, &trace_covered_result?(&1, opts.trace_covered_paths))
    indexed_results = Enum.filter(results, &indexed_result?/1)
    entries = entries_from_indexed_results(indexed_results, opts)
    manifest_entries = manifest_entries_from_results(results)

    {entries, manifest_entries}
  end

  defp index_opts(opts) do
    %{
      project_source_paths: opts |> Keyword.get(:project_source_paths, []) |> MapSet.new(),
      traced_beam_paths: opts |> Keyword.get(:traced_beam_paths, []) |> MapSet.new(),
      trace_covered_paths: opts |> Keyword.get(:trace_covered_paths, []) |> MapSet.new()
    }
  end

  defp trace_covered_result?(
         {:indexed, source_path, _metadata, _manifest_entry},
         trace_covered_paths
       ) do
    MapSet.member?(trace_covered_paths, source_path)
  end

  defp trace_covered_result?({:skipped, %Manifest.Entry{} = manifest_entry}, trace_covered_paths) do
    trace_covered_manifest_entry?(manifest_entry, trace_covered_paths)
  end

  defp trace_covered_result?(_result, _trace_covered_paths), do: false

  defp trace_covered_manifest_entry?(%Manifest.Entry{} = entry, trace_covered_paths) do
    Enum.any?([entry.output_path, entry.source_path], &MapSet.member?(trace_covered_paths, &1))
  end

  defp indexed_result?({:indexed, _source_path, _metadata, _manifest_entry}), do: true
  defp indexed_result?(_result), do: false

  defp manifest_entries_from_results(results) do
    Enum.map(results, fn
      {:indexed, _source_path, _metadata, manifest_entry} -> manifest_entry
      {:skipped, manifest_entry} -> manifest_entry
    end)
  end

  defp entries_from_indexed_results([], _opts), do: []

  defp entries_from_indexed_results(results, opts) do
    source_lines_by_path = source_lines_by_path(results)

    results
    |> Enum.group_by(fn {:indexed, source_path, _metadata, _manifest_entry} -> source_path end)
    |> Enum.flat_map(fn {source_path, results} ->
      entries_from_group(source_path, results, source_lines_by_path, opts)
    end)
  end

  defp entries_from_group(source_path, results, source_lines_by_path, opts) do
    entries =
      results
      |> Enum.flat_map(fn {:indexed, _source_path, metadata, _manifest_entry} ->
        metadata_entries(metadata, Map.get(source_lines_by_path, source_path, %{}), [])
      end)

    entries = with_source_document_ranges(source_path, entries)

    {structure_entries, reference_entries} =
      fallback_reference_entries(source_path, results, opts)

    structure_entries ++ entries ++ reference_entries
  end

  defp fallback_reference_entries(source_path, results, opts) do
    if source_reference_fallback?(source_path, results, opts) do
      {structure_entries, reference_entries} =
        source_path
        |> source_reference_entries()
        |> Enum.split_with(&block_structure?/1)

      {ensure_structure_entries(source_path, structure_entries), reference_entries}
    else
      {[Entry.block_structure(source_path, %{root: %{}})], []}
    end
  end

  defp ensure_structure_entries(source_path, []),
    do: [Entry.block_structure(source_path, %{root: %{}})]

  defp ensure_structure_entries(_source_path, structure_entries), do: structure_entries

  defp source_reference_fallback?(source_path, results, opts) do
    Path.extname(source_path) == ".ex" and
      MapSet.member?(opts.project_source_paths, source_path) and
      Enum.any?(results, fn {:indexed, _source_path, _metadata, manifest_entry} ->
        not MapSet.member?(opts.traced_beam_paths, manifest_entry.input_path)
      end)
  end

  defp source_reference_entries(source_path) do
    with {:ok, source} <- File.read(source_path),
         {:ok, entries} <- Source.index(source_path, source, @source_reference_extractors) do
      Enum.filter(entries, &reference_or_structure?/1)
    else
      _ -> []
    end
  end

  defp reference_or_structure?(%Entry{subtype: :reference}), do: true
  defp reference_or_structure?(%Entry{} = entry), do: block_structure?(entry)

  defp block_structure?(%Entry{type: :metadata, subtype: :block_structure}), do: true
  defp block_structure?(_entry), do: false

  defp with_source_document_ranges(source_path, entries) when is_binary(source_path) do
    case source_document(source_path) do
      %Document{} = document -> Enum.map(entries, &put_source_document(&1, document))
      nil -> entries
    end
  end

  defp with_source_document_ranges(_source_path, entries), do: entries

  defp put_source_document(%Entry{} = entry, %Document{} = document) do
    %Entry{
      entry
      | range: document_range(entry.range, document),
        block_range: document_range(entry.block_range, document)
    }
  end

  defp document_range(%Range{} = range, %Document{} = document) do
    Range.new(
      document_position(range.start, document),
      document_position(range.end, document)
    )
  end

  defp document_range(nil, _document), do: nil

  defp document_position(%Position{} = position, %Document{} = document) do
    Position.new(document, position.line, position.character)
  end

  defp source_document(path) when is_binary(path) do
    case File.read(path) do
      {:ok, source} -> Document.new(Document.Path.to_uri(path), source, 1)
      _ -> nil
    end
  end

  defp metadata_from_beam({beam_path, beam_stat}) do
    case extract_metadata_from_path(beam_path) do
      {:ok, metadata} -> metadata_result_from_beam(beam_path, beam_stat, metadata)
      :error -> skipped_result_from_beam(beam_path, beam_stat, nil, nil)
    end
  end

  defp metadata_result_from_beam(beam_path, beam_stat, metadata) do
    metadata = normalize_metadata_source_path(metadata)
    source_path = Map.get(metadata, :file)
    source_stat_result = stat_source(source_path)

    if fresh_beam?(beam_stat, source_stat_result) do
      {:ok, manifest_entry} =
        Manifest.Entry.beam(beam_path, source_path, beam_stat, source_stat_result)

      [{:indexed, source_path, metadata, manifest_entry}]
    else
      skipped_result_from_beam(beam_path, beam_stat, source_path, source_stat_result)
    end
  end

  defp stat_source(source_path) when is_binary(source_path) do
    case File.stat(source_path) do
      {:ok, %File.Stat{} = stat} -> {:ok, stat}
      _ -> :error
    end
  end

  defp stat_source(_source_path), do: :error

  defp fresh_beam?(%File.Stat{} = beam_stat, {:ok, %File.Stat{} = source_stat}) do
    beam_stat.mtime >= source_stat.mtime
  end

  defp fresh_beam?(_beam_stat, _source_stat), do: false

  defp skipped_result_from_beam(beam_path, beam_stat, source_path, source_stat_result) do
    {:ok, manifest_entry} =
      Manifest.Entry.skipped_beam(
        beam_path,
        source_path,
        beam_stat,
        source_stat_result
      )

    [{:skipped, manifest_entry}]
  end

  # The debug-info chunk data is backend-owned and opaque. The public contract is
  # to ask the backend to decode it into the Elixir debug-info format we consume.
  defp extract_metadata_from_path(path) when is_binary(path) do
    path
    |> String.to_charlist()
    |> extract_metadata()
  end

  defp extract_metadata_from_binary(beam) when is_binary(beam) do
    extract_metadata(beam)
  end

  defp extract_metadata(beam_or_path) do
    with {:ok, {module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(beam_or_path, [:debug_info]),
         {:ok, metadata} when is_map(metadata) <- backend.debug_info(:elixir_v1, module, data, []) do
      {:ok, metadata}
    else
      _ -> :error
    end
  catch
    _kind, _reason -> :error
  end

  defp exported_definitions(metadata, definition) do
    protocol_callbacks = protocol_callbacks(metadata)

    metadata
    |> Map.get(:definitions, [])
    |> Enum.flat_map(&exported_definition(&1, definition, protocol_callbacks))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp exported_definition(
         {{name, arity}, definition, metadata, _clauses},
         target,
         protocol_callbacks
       )
       when definition == target and definition in [:def, :defmacro] do
    defaults = Keyword.get(metadata, :defaults, 0)

    for arity <- expanded_arities(name, arity, defaults, metadata, protocol_callbacks) do
      {name, arity}
    end
  end

  defp exported_definition(_definition, _target_definition, _protocol_callbacks), do: []

  defp struct_fields(metadata), do: metadata |> Map.get(:struct) |> struct_field_list()

  defp struct_field_list(nil), do: nil

  defp struct_field_list(struct) when is_list(struct) do
    Enum.map(struct, &struct_field/1)
  end

  defp struct_field(%{field: field, required: required?}) when is_atom(field) do
    %{field: field, required?: required?}
  end

  defp struct_field(%{field: field, default: _default}) when is_atom(field) do
    %{field: field, required?: false}
  end

  defp maybe_put_source_path(metadata, source_path) when is_binary(source_path) do
    Map.put(metadata, :file, Forge.Path.native(source_path))
  end

  defp maybe_put_source_path(metadata, _source_path), do: metadata

  defp normalize_metadata_source_path(%{file: source_path} = metadata)
       when is_binary(source_path) do
    %{metadata | file: Forge.Path.native(source_path)}
  end

  defp normalize_metadata_source_path(metadata), do: metadata

  defp metadata_entries(metadata, source_lines, opts) do
    context = metadata |> entry_context() |> Map.put(:source_lines, source_lines)

    module_entries(metadata, context, module_range(metadata, source_lines)) ++
      function_entries(metadata, context, opts)
  end

  defp entry_context(metadata) do
    module = Map.fetch!(metadata, :module)

    %{
      app: ApplicationCache.application(module),
      module: module,
      root_block: Block.root(),
      source_path: Map.fetch!(metadata, :file)
    }
  end

  defp module_entries(metadata, context, module_range) do
    case protocol_implementation(metadata) do
      {:ok, protocol} ->
        [
          module_definition(context, :module, module_range),
          protocol_implementation_definition(context, protocol, module_range)
        ]

      :error ->
        module_definition_entries(metadata, context, module_range)
    end
  end

  defp module_definition_entries(metadata, context, module_range) do
    entries = [module_definition(context, module_type(metadata), module_range)]

    if is_nil(Map.get(metadata, :struct)) do
      entries
    else
      entries ++ [module_definition(context, :struct, module_range)]
    end
  end

  defp module_definition(context, type, range) do
    Entry.definition(
      context.source_path,
      context.root_block,
      Subject.module(context.module),
      type,
      range,
      context.app
    )
  end

  defp protocol_implementation_definition(context, protocol, range) do
    Entry.definition(
      context.source_path,
      context.root_block,
      Subject.module(protocol),
      {:protocol, :implementation},
      range,
      ApplicationCache.application(protocol)
    )
  end

  defp function_entries(metadata, context, opts) do
    definitions = Map.get(metadata, :definitions, [])
    protocol_callbacks = protocol_callbacks(metadata)
    delegated_mfas = delegated_mfas_by_name_and_arity(metadata, context.source_lines)
    default_wrappers = default_wrapper_identities(definitions)
    include_private? = Keyword.get(opts, :include_private?, false)

    definitions
    |> Enum.flat_map(
      &function_entries_from_definition(
        &1,
        context,
        protocol_callbacks,
        delegated_mfas,
        default_wrappers,
        include_private?
      )
    )
    |> Enum.uniq_by(&function_entry_key/1)
  end

  defp function_entry_key(%Entry{} = entry) do
    {entry.path, entry.subject, entry.type, entry.subtype, range_key(entry.range)}
  end

  defp range_key(%Range{start: start, end: finish}) do
    {start.line, start.character, finish.line, finish.character}
  end

  defp range_key(_range), do: nil

  defp function_entries_from_definition(
         {{name, arity}, definition, metadata, clauses},
         context,
         protocol_callbacks,
         delegated_mfas,
         default_wrappers,
         include_private?
       )
       when definition in [:def, :defp, :defmacro, :defmacrop] do
    cond do
      not indexed_definition?(definition, include_private?) ->
        []

      default_wrapper?(name, arity, definition, clauses, default_wrappers) ->
        []

      Keyword.get(metadata, :generated, false) and not Keyword.has_key?(metadata, :context) ->
        []

      true ->
        name
        |> expanded_arities(
          arity,
          Keyword.get(metadata, :defaults, 0),
          metadata,
          protocol_callbacks
        )
        |> Enum.flat_map(
          &entry_for_definition_arity(
            context,
            name,
            &1,
            definition,
            metadata,
            clauses,
            context.source_lines,
            delegated_mfas
          )
        )
    end
  end

  defp function_entries_from_definition(
         _definition,
         _context,
         _protocol_callbacks,
         _delegated_mfas,
         _default_wrappers,
         _include_private?
       ),
       do: []

  defp indexed_definition?(definition, true),
    do: definition in [:def, :defp, :defmacro, :defmacrop]

  defp indexed_definition?(definition, false), do: definition in [:def, :defmacro]

  defp default_wrapper_identities(definitions) do
    definitions
    |> Enum.flat_map(fn
      {{name, arity}, definition, metadata, _clauses}
      when definition in [:def, :defp, :defmacro, :defmacrop] ->
        case Keyword.get(metadata, :defaults, 0) do
          defaults when defaults > 0 ->
            for wrapper_arity <- (arity - defaults)..(arity - 1),
                do: {name, wrapper_arity, definition}

          _defaults ->
            []
        end

      _definition ->
        []
    end)
    |> MapSet.new()
  end

  defp default_wrapper?(name, arity, definition, clauses, default_wrappers) do
    MapSet.member?(default_wrappers, {name, arity, definition}) and
      default_wrapper_clauses?(clauses, definition, name)
  end

  defp default_wrapper_clauses?([_clause | _rest] = clauses, definition, name) do
    Enum.all?(clauses, &default_wrapper_clause?(&1, definition, name))
  end

  defp default_wrapper_clauses?(_clauses, _definition, _name), do: false

  defp default_wrapper_clause?(
         {_metadata, _args, [], {:super, metadata, _defaults}},
         definition,
         name
       ) do
    Keyword.get(metadata, :super) == {definition, name}
  end

  defp default_wrapper_clause?(_clause, _definition, _name), do: false

  defp entry_for_definition_arity(
         context,
         name,
         arity,
         definition,
         metadata,
         clauses,
         source_lines,
         delegated_mfas
       ) do
    case Map.get(delegated_mfas, {name, arity}) do
      nil ->
        function_clause_entries(context, name, arity, definition, metadata, clauses, source_lines)

      delegated_mfa ->
        [delegate_entry(context, name, arity, delegated_mfa)]
    end
  end

  defp function_clause_entries(context, name, arity, definition, metadata, clauses, source_lines) do
    clauses
    |> function_clause_metadata(metadata)
    |> Enum.map(&function_entry(context, name, arity, definition, &1, source_lines))
  end

  defp function_clause_metadata(clauses, definition_metadata) do
    clause_metadata =
      clauses
      |> List.wrap()
      |> Enum.flat_map(&clause_metadata/1)

    case clause_metadata do
      [] -> [definition_metadata]
      [_ | _] -> clause_metadata
    end
  end

  defp clause_metadata({metadata, _args, _guards, _body}) when is_list(metadata), do: [metadata]
  defp clause_metadata(_clause), do: []

  defp function_entry(context, name, arity, definition, metadata, source_lines) do
    Entry.definition(
      context.source_path,
      context.root_block,
      Subject.mfa(context.module, name, arity),
      function_entry_type(definition),
      definition_range(metadata, source_lines, name, definition),
      context.app
    )
  end

  defp function_entry_type(:def), do: {:function, :public}
  defp function_entry_type(:defp), do: {:function, :private}
  defp function_entry_type(:defmacro), do: {:macro, :public}
  defp function_entry_type(:defmacrop), do: {:macro, :private}

  defp delegate_entry(context, name, arity, delegated_mfa) do
    context.source_path
    |> Entry.definition(
      context.root_block,
      Subject.mfa(context.module, name, arity),
      {:function, :delegate},
      delegated_mfa.range,
      context.app
    )
    |> Entry.put_metadata(%{
      original_mfa: Subject.mfa(delegated_mfa.module, delegated_mfa.name, delegated_mfa.arity)
    })
  end

  defp delegated_mfas_by_name_and_arity(metadata, source_lines) do
    metadata
    |> Map.get(:definitions, [])
    |> Enum.flat_map(&delegated_mfas_from_definition(&1, source_lines))
    |> Map.new()
  end

  defp delegated_mfas_from_definition({{name, arity}, :def, metadata, clauses}, source_lines) do
    with true <- delegate_metadata?(metadata),
         {:ok, module, delegated_name, delegated_arity} <- delegated_mfa_from_clause(clauses) do
      defaults = Keyword.get(metadata, :defaults, 0)

      delegated_mfa = %{
        module: module,
        name: delegated_name,
        arity: delegated_arity,
        range: definition_range(metadata, source_lines, name, :def)
      }

      for expanded_arity <- (arity - defaults)..arity do
        {{name, expanded_arity}, delegated_mfa}
      end
    else
      _ -> []
    end
  end

  defp delegated_mfas_from_definition(_definition, _source_lines), do: []

  defp delegate_metadata?(metadata) do
    Keyword.has_key?(metadata, :line) and not Keyword.has_key?(metadata, :column) and
      not Keyword.has_key?(metadata, :context)
  end

  defp delegated_mfa_from_clause([{_metadata, args, [], body}]) do
    with {{:., _dot_metadata, [module, name]}, _call_metadata, call_args} <- body,
         true <- is_atom(module),
         true <- is_atom(name),
         true <- same_variables?(args, call_args) do
      {:ok, module, name, length(call_args)}
    else
      _ -> :error
    end
  end

  defp delegated_mfa_from_clause(_clauses), do: :error

  defp same_variables?(args, call_args) when length(args) == length(call_args) do
    args
    |> Enum.zip(call_args)
    |> Enum.all?(fn {arg, call_arg} -> variable_identity(arg) == variable_identity(call_arg) end)
  end

  defp same_variables?(_args, _call_args), do: false

  defp variable_identity({name, metadata, context}) when is_atom(name) and is_list(metadata) do
    {name, Keyword.get(metadata, :version), context}
  end

  defp variable_identity(_ast), do: :error

  defp module_type(%{attributes: attributes}) do
    if Keyword.has_key?(attributes, :__protocol__), do: {:protocol, :definition}, else: :module
  end

  defp module_type(_), do: :module

  defp protocol_implementation(%{attributes: attributes}) do
    with impl when is_list(impl) <- Keyword.get(attributes, :__impl__),
         protocol when is_atom(protocol) <- Keyword.get(impl, :protocol) do
      {:ok, protocol}
    else
      _ -> :error
    end
  end

  defp protocol_implementation(_metadata), do: :error

  defp protocol_callbacks(metadata) do
    metadata
    |> Map.get(:definitions, [])
    |> Enum.find_value([], fn
      {{:__protocol__, 1}, :def, _definition_metadata, clauses} ->
        protocol_callback_clauses(clauses)

      _definition ->
        nil
    end)
    |> MapSet.new()
  end

  defp protocol_callback_clauses(clauses) do
    clauses
    |> Enum.find_value([], fn
      {_metadata, [:functions], [], functions} when is_list(functions) -> functions
      _clause -> nil
    end)
    |> Enum.flat_map(fn
      {name, arity} when is_atom(name) and is_integer(arity) -> [{name, arity}]
      _function -> []
    end)
  end

  defp expanded_arities(name, arity, defaults, definition_metadata, protocol_callbacks) do
    arities = Enum.to_list((arity - defaults)..arity)

    if Keyword.has_key?(definition_metadata, :context) do
      Enum.filter(arities, &MapSet.member?(protocol_callbacks, {name, &1}))
    else
      arities
    end
  end

  defp definition_range(metadata, source_lines, name, definition) do
    {line, fallback_column} = metadata_position(metadata) || {1, 1}
    fallback_span = {fallback_column, name |> Atom.to_string() |> String.length()}

    {column, length} =
      case source_function_span(source_lines, line, name, definition) do
        {:ok, span} -> span
        :error -> fallback_span
      end

    range(line, column, length)
  end

  defp source_function_span(source_lines, line, name, definition) do
    case Map.get(source_lines, line) do
      line_text when is_binary(line_text) ->
        function_definition_name_span(line_text, name, definition)

      _ ->
        :error
    end
  end

  defp function_definition_name_span(line_text, name, definition) do
    with {:ok, search_start_byte} <- function_name_search_start(line_text, definition),
         {:ok, start_byte, length} <-
           function_name_match(line_text, search_start_byte, Atom.to_string(name)) do
      byte_span_to_column_span(line_text, start_byte, length)
    end
  end

  defp function_name_search_start(line_text, definition) do
    definition
    |> function_definition_keywords()
    |> Enum.find_value(:error, fn keyword ->
      line_text
      |> :binary.matches(keyword)
      |> Enum.find(fn {byte_index, length} ->
        not function_name_character_before?(line_text, byte_index) and
          not function_name_character_at?(line_text, byte_index + length)
      end)
      |> case do
        {byte_index, length} -> {:ok, byte_index + length}
        nil -> nil
      end
    end)
  end

  defp function_definition_keywords(:def), do: ["defdelegate", "def"]
  defp function_definition_keywords(:defp), do: ["defp"]
  defp function_definition_keywords(:defmacro), do: ["defguard", "defmacro"]
  defp function_definition_keywords(:defmacrop), do: ["defguardp", "defmacrop"]

  defp function_name_match(line_text, search_start, name) do
    matches =
      :binary.matches(line_text, name, scope: {search_start, byte_size(line_text) - search_start})

    case Enum.find(matches, fn {byte_index, length} ->
           function_name_boundary?(line_text, byte_index, length)
         end) do
      {byte_index, length} -> {:ok, byte_index, length}
      nil -> :error
    end
  end

  defp function_name_boundary?(line_text, byte_index, length) do
    not function_name_character_before?(line_text, byte_index) and
      not function_name_character_at?(line_text, byte_index + length)
  end

  defp function_name_character_before?(_line_text, 0), do: false

  defp function_name_character_before?(line_text, byte_index) do
    function_name_character_at?(line_text, byte_index - 1)
  end

  defp function_name_character_at?(line_text, byte_index)
       when byte_index >= byte_size(line_text) do
    false
  end

  defp function_name_character_at?(line_text, byte_index) do
    character = :binary.at(line_text, byte_index)

    character in ?A..?Z or character in ?a..?z or character in ?0..?9 or character in [?_, ??, ?!]
  end

  # BEAM debug metadata stores nested modules under their expanded names, but the
  # source often only contains the visible suffix (`defmodule Child`). Scan the
  # definition line for the source spelling before falling back to compiler data.
  defp module_range(metadata, source_lines) do
    {line, fallback_column} = metadata_position(metadata) || {1, 1}
    module_name = metadata |> Map.fetch!(:module) |> Forge.Formats.module()

    fallback_span = {fallback_column, String.length(module_name)}

    {column, length} =
      case source_definition_span(metadata, source_lines, line, module_name) do
        {:ok, span} -> span
        :error -> fallback_span
      end

    range(line, column, length)
  end

  defp source_definition_span(metadata, source_lines, line, module_name) do
    case Map.get(source_lines, line) do
      line_text when is_binary(line_text) -> definition_span(metadata, line_text, module_name)
      _ -> :error
    end
  end

  defp definition_span(metadata, line_text, module_name) do
    if protocol_implementation?(metadata) do
      defimpl_span(line_text)
    else
      module_definition_name_span(line_text, module_name)
    end
  end

  defp defimpl_span(line_text) do
    with {start_byte, _length} <- :binary.match(line_text, "defimpl"),
         {:ok, end_byte} <- defimpl_end_byte(line_text, start_byte) do
      byte_span_to_column_span(line_text, start_byte, end_byte - start_byte)
    else
      _ -> :error
    end
  end

  defp defimpl_end_byte(line_text, start_byte) do
    rest = binary_part(line_text, start_byte, byte_size(line_text) - start_byte)

    case :binary.match(rest, " do") do
      {do_byte, do_length} -> {:ok, start_byte + do_byte + do_length}
      :nomatch -> {:ok, line_text |> String.trim_trailing() |> byte_size()}
    end
  end

  defp protocol_implementation?(metadata) do
    match?({:ok, _protocol}, protocol_implementation(metadata))
  end

  defp module_definition_name_span(line_text, module_name) do
    with {:ok, search_start_byte} <- module_name_search_start(line_text),
         {:ok, start_byte, length} <-
           module_name_match(line_text, search_start_byte, module_name) do
      byte_span_to_column_span(line_text, start_byte, length)
    end
  end

  defp module_name_search_start(line_text) do
    ["defmodule", "defprotocol"]
    |> Enum.flat_map(&:binary.matches(line_text, &1))
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
    |> case do
      {byte_index, length} -> {:ok, byte_index + length}
      nil -> :error
    end
  end

  defp module_name_match(line_text, search_start, module_name) do
    line_text
    |> module_name_suffixes(module_name)
    |> Enum.find_value(:error, fn candidate ->
      match =
        line_text
        |> :binary.matches(candidate, scope: {search_start, byte_size(line_text) - search_start})
        |> Enum.find(fn {byte_index, length} ->
          module_name_boundary?(line_text, byte_index, length)
        end)

      case match do
        {byte_index, length} -> {:ok, byte_index, length}
        nil -> nil
      end
    end)
  end

  defp module_name_boundary?(line_text, byte_index, length) do
    not module_name_character_before?(line_text, byte_index) and
      not module_name_character_at?(line_text, byte_index + length)
  end

  defp module_name_character_before?(_line_text, 0), do: false

  defp module_name_character_before?(line_text, byte_index) do
    module_name_character_at?(line_text, byte_index - 1)
  end

  defp module_name_character_at?(line_text, byte_index) when byte_index >= byte_size(line_text) do
    false
  end

  defp module_name_character_at?(line_text, byte_index) do
    character = :binary.at(line_text, byte_index)

    character in ?A..?Z or character in ?a..?z or character in ?0..?9 or character in [?_, ?.]
  end

  defp module_name_suffixes(line_text, module_name) do
    segments = String.split(module_name, ".")

    suffixes =
      for index <- 0..(length(segments) - 1), do: segments |> Enum.drop(index) |> Enum.join(".")

    module_alias_suffixes = Enum.map(suffixes, &"__MODULE__.#{&1}")

    Enum.filter(module_alias_suffixes ++ suffixes, &String.contains?(line_text, &1))
  end

  defp byte_span_to_column_span(line_text, start_byte, byte_length) when byte_length > 0 do
    column = line_text |> binary_part(0, start_byte) |> String.length()
    length = line_text |> binary_part(start_byte, byte_length) |> String.length()

    {:ok, {column + 1, length}}
  end

  defp byte_span_to_column_span(_line_text, _start_byte, _byte_length), do: :error

  defp source_lines_by_path(results) do
    results
    |> Enum.group_by(
      fn {:indexed, source_path, _metadata, _manifest_entry} -> source_path end,
      fn {:indexed, _source_path, metadata, _manifest_entry} -> metadata_lines(metadata) end
    )
    |> Map.new(fn {source_path, line_groups} ->
      {source_path, source_lines(source_path, Enum.concat(line_groups))}
    end)
  end

  defp source_lines(%{file: source_path} = metadata) when is_binary(source_path) do
    source_lines(source_path, metadata_lines(metadata))
  end

  defp source_lines(_metadata), do: %{}

  defp source_lines(source_path, lines) do
    source_lines = lines |> Enum.filter(&valid_line?/1) |> Enum.uniq() |> Enum.sort()

    read_source_lines(source_path, source_lines)
  end

  defp read_source_lines(_source_path, []), do: %{}

  defp read_source_lines(source_path, lines) do
    source_path
    |> File.stream!(:line, [])
    |> Stream.with_index(1)
    |> Enum.reduce_while({lines, %{}}, &collect_source_line/2)
    |> elem(1)
  rescue
    _ -> %{}
  end

  defp collect_source_line(_source_line, {[], lines_by_number}) do
    {:halt, {[], lines_by_number}}
  end

  defp collect_source_line({line_text, line_number}, {[next_line], lines_by_number})
       when line_number == next_line do
    {:halt, {[], Map.put(lines_by_number, line_number, line_text)}}
  end

  defp collect_source_line({line_text, line_number}, {[next_line | rest], lines_by_number})
       when line_number == next_line do
    {:cont, {rest, Map.put(lines_by_number, line_number, line_text)}}
  end

  defp collect_source_line(
         {_line_text, line_number},
         {[next_line | _rest] = lines, lines_by_number}
       )
       when line_number < next_line do
    {:cont, {lines, lines_by_number}}
  end

  defp collect_source_line(_source_line, {[_next_line | rest], lines_by_number}) do
    {:cont, {rest, lines_by_number}}
  end

  defp valid_line?(line), do: is_integer(line) and line > 0

  defp metadata_line(metadata) do
    case metadata_position(metadata) do
      {line, _column} -> line
      nil -> nil
    end
  end

  defp metadata_lines(metadata) do
    [metadata_line(metadata) | definition_lines(metadata)]
  end

  defp definition_lines(%{definitions: definitions}) when is_list(definitions) do
    Enum.flat_map(definitions, fn
      {_name_arity, definition, metadata, clauses}
      when definition in [:def, :defp, :defmacro, :defmacrop] ->
        [metadata_line(metadata) | clause_lines(clauses)]

      _definition ->
        []
    end)
  end

  defp definition_lines(_metadata), do: []

  defp clause_lines(clauses) do
    clauses
    |> List.wrap()
    |> Enum.flat_map(fn
      {metadata, _args, _guards, _body} -> [metadata_line(metadata)]
      _clause -> []
    end)
  end

  defp metadata_position(metadata) do
    case metadata_value(metadata, :anno) || metadata_value(metadata, :line) do
      {line, column} -> {line, column}
      line when is_integer(line) -> {line, 1}
      _ -> nil
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata), do: Map.get(metadata, key)
  defp metadata_value(metadata, key) when is_list(metadata), do: Keyword.get(metadata, key)
  defp metadata_value(_metadata, _key), do: nil

  defp range(line, column, length) do
    Range.new(
      %Position{line: line, character: column, starting_index: 1},
      %Position{line: line, character: column + max(length, 1), starting_index: 1}
    )
  end

  defp task_result!({:ok, items}), do: items

  defp task_result!({:exit, reason}),
    do: raise("Indexing task failed: #{Exception.format_exit(reason)}")

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp file_label([_beam]), do: "file"
  defp file_label(_beams), do: "files"
end
