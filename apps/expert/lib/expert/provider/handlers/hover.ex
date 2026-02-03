defmodule Expert.Provider.Handlers.Hover do
  @behaviour Expert.Provider.Handler

  alias Engine.Search.Store
  alias Expert.ActiveProjects
  alias Expert.EngineApi
  alias Expert.Provider.Markdown
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.CodeIntelligence.Docs
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Project
  alias Forge.Search.Indexer.Entry
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def handle(%Requests.TextDocumentHover{params: %Structures.HoverParams{} = params}) do
    document = Document.Container.context_document(params, nil)
    projects = ActiveProjects.projects()
    project = Project.project_for_document(projects, document)

    maybe_hover =
      with {:ok, _document, %Ast.Analysis{} = analysis} <-
             Document.Store.fetch(document.uri, :analysis),
           {:ok, entity, range} <- resolve_entity(project, analysis, params.position),
           {:ok, markdown} <- hover_content(entity, project) do
        content = Markdown.to_content(markdown)
        %Structures.Hover{contents: content, range: range}
      else
        {:error, :no_doc} ->
          nil

        {:error, :no_type} ->
          nil

        :error ->
          nil

        _ ->
          try_elixir_sense(project, document, params.position)
      end

    {:ok, maybe_hover}
  end

  defp resolve_entity(%Project{} = project, %Analysis{} = analysis, %Position{} = position) do
    EngineApi.resolve_entity(project, analysis, position)
  end

  defp try_elixir_sense(project, document, position) do
    case EngineApi.hover(project, document, position) do
      {:ok, markdown, range} ->
        content = Markdown.to_content(markdown)
        %Structures.Hover{contents: content, range: range}

      {:error, _} ->
        nil
    end
  end

  defp hover_content({kind, module}, %Project{} = project) when kind in [:module, :struct] do
    case EngineApi.docs(project, module, exclude_hidden: false) do
      {:ok, %Docs{} = module_docs} ->
        header = module_header(kind, module_docs)
        types = module_header_types(kind, module_docs)

        additional_sections = [
          module_doc(module_docs.doc),
          module_footer(kind, module_docs)
        ]

        if Enum.all?([types | additional_sections], &empty?/1) do
          {:error, :no_doc}
        else
          header_block = "#{header}\n\n#{types}" |> String.trim() |> Markdown.code_block()
          {:ok, Markdown.join_sections([header_block | additional_sections])}
        end

      _ ->
        {:error, :no_doc}
    end
  end

  defp hover_content({:call, module, fun, arity}, %Project{} = project) do
    # Try to resolve delegates to get docs from the original implementation.
    # If function is found in index, use the resolved target for docs.
    # If not found in index, try the module directly, then fallback to ElixirSense.
    {target_module, target_fun, target_arity, indexed?} =
      resolve_call_target(project, module, fun, arity)

    with {:ok, %Docs{} = module_docs} <- EngineApi.docs(project, target_module),
         {:ok, entries} <- Map.fetch(module_docs.functions_and_macros, target_fun) do
      sections =
        entries
        |> Enum.sort_by(& &1.arity)
        |> Enum.filter(&(&1.arity >= target_arity))
        |> Enum.map(&entry_content/1)

      {:ok, Markdown.join_sections(sections, Markdown.separator())}
    else
      # If function was indexed (found in our Store), don't fallback - it's intentionally
      # without docs (private, or docs deliberately omitted)
      _ when indexed? ->
        :error

      # Not indexed - could be a dependency function, imported function, or private function.
      # Fall back to ElixirSense which can resolve imports to their source module.
      _ ->
        {:error, :not_found}
    end
  end

  defp hover_content({:type, module, type, arity}, %Project{} = project) do
    with {:ok, %Docs{} = module_docs} <- EngineApi.docs(project, module),
         {:ok, entries} <- Map.fetch(module_docs.types, type) do
      case Enum.find(entries, &(&1.arity == arity)) do
        %Docs.Entry{} = entry ->
          {:ok, entry_content(entry)}

        _ ->
          {:error, :no_type}
      end
    end
  end

  defp hover_content({:module_attribute, module, attribute_name}, %Project{} = project) do
    case module_attribute_definition_text(project, module, attribute_name) do
      {:ok, definition_text} ->
        {:ok, Markdown.code_block(definition_text)}

      {:error, _} ->
        # Fall back to just showing the attribute name
        {:ok, Markdown.code_block("@#{attribute_name}")}
    end
  end

  defp hover_content(type, _) do
    {:error, {:unsupported, type}}
  end

  defp resolve_call_target(project, module, fun, arity) do
    mfa = Forge.Formats.mfa(module, fun, arity)

    case EngineApi.call(project, Store, :exact, [mfa, [subtype: :definition]]) do
      {:ok, [%Entry{type: {:function, :delegate}, metadata: %{original_mfa: original_mfa}} | _]} ->
        # Found a delegate - try to resolve to the original function
        case parse_mfa(original_mfa) do
          {target_module, target_fun, target_arity} ->
            {target_module, target_fun, target_arity, true}

          nil ->
            # Couldn't parse MFA, fall back to the delegate module itself
            {module, fun, arity, true}
        end

      {:ok, [%Entry{type: {:function, _}} | _]} ->
        # Regular function found in index
        {module, fun, arity, true}

      _ ->
        # Not found in index
        {module, fun, arity, false}
    end
  end

  defp parse_mfa(mfa_string) do
    # Parse "Module.Name.function/arity" format
    case Regex.run(~r/^(.+)\.([^.\/]+)\/(\d+)$/, mfa_string) do
      [_, module_str, fun_str, arity_str] ->
        module =
          if String.starts_with?(module_str, ":") do
            module_str |> String.trim_leading(":") |> String.to_existing_atom()
          else
            String.to_existing_atom("Elixir." <> module_str)
          end

        fun = String.to_atom(fun_str)
        arity = String.to_integer(arity_str)
        {module, fun, arity}

      _ ->
        nil
    end
  end

  defp module_header(:module, %Docs{module: module}) do
    Ast.Module.name(module)
  end

  defp module_header(:struct, %Docs{module: module}) do
    "%#{Ast.Module.name(module)}{}"
  end

  defp module_header_types(:module, %Docs{}), do: ""

  defp module_header_types(:struct, %Docs{} = docs) do
    docs.types
    |> Map.get(:t, [])
    |> sort_entries()
    |> Enum.flat_map(& &1.defs)
    |> Enum.join("\n\n")
  end

  defp module_doc(s) when is_binary(s), do: s
  defp module_doc(_), do: nil

  defp module_footer(:module, docs) do
    callbacks = format_callbacks(docs.callbacks)

    unless empty?(callbacks) do
      Markdown.section(callbacks, header: "Callbacks")
    end
  end

  defp module_footer(:struct, _docs), do: nil

  defp entry_content(%Docs.Entry{kind: fn_or_macro} = entry)
       when fn_or_macro in [:function, :macro] do
    call_header = call_header(entry)
    specs = Enum.map_join(entry.defs, "\n", &("@spec " <> &1))

    header =
      [call_header, specs]
      |> Markdown.join_sections()
      |> String.trim()
      |> Markdown.code_block()

    Markdown.join_sections([header, entry_doc_content(entry.doc)])
  end

  defp entry_content(%Docs.Entry{kind: :type} = entry) do
    header =
      Markdown.code_block("""
      #{call_header(entry)}

      #{type_defs(entry)}\
      """)

    Markdown.join_sections([header, entry_doc_content(entry.doc)])
  end

  defp module_attribute_definition_text(%Project{} = project, module, attribute_name) do
    case EngineApi.call(project, Store, :exact, [
           "@#{attribute_name}",
           [type: :module_attribute, subtype: :definition]
         ]) do
      {:ok, []} ->
        {:error, :no_definition}

      {:ok, entries} ->
        entries
        |> filter_entries_by_module(module)
        |> fetch_first_definition_text(project)

      error ->
        error
    end
  end

  defp filter_entries_by_module(entries, nil), do: entries

  defp filter_entries_by_module(entries, module) do
    module_hint = module |> Module.split() |> List.last() |> Macro.underscore()

    filtered =
      Enum.filter(entries, fn %Entry{path: path} ->
        String.contains?(String.downcase(path), module_hint)
      end)

    if filtered == [], do: entries, else: filtered
  end

  defp fetch_first_definition_text([], _project), do: {:error, :no_definition}

  defp fetch_first_definition_text([%Entry{path: path, range: range} | _], project) do
    uri = Document.Path.ensure_uri(path)

    case EngineApi.call(project, Document.Store, :open_temporary, [uri]) do
      {:ok, document} ->
        text = Document.fragment(document, range.start, range.end)
        {:ok, String.trim(text)}

      error ->
        error
    end
  end

  @one_line_header_cutoff 50

  defp call_header(%Docs.Entry{kind: :type} = entry) do
    module_name = Ast.Module.name(entry.module)

    one_line_header = "#{module_name}.#{entry.name}/#{entry.arity}"

    two_line_header =
      "#{last_module_name(module_name)}.#{entry.name}/#{entry.arity}\n#{module_name}"

    if String.length(one_line_header) >= @one_line_header_cutoff do
      two_line_header
    else
      one_line_header
    end
  end

  defp call_header(%Docs.Entry{kind: maybe_macro} = entry) do
    [signature | _] = entry.signature
    module_name = Ast.Module.name(entry.module)

    macro_prefix =
      if maybe_macro == :macro do
        "(macro) "
      else
        ""
      end

    one_line_header = "#{macro_prefix}#{module_name}.#{signature}"

    two_line_header =
      "#{macro_prefix}#{last_module_name(module_name)}.#{signature}\n#{module_name}"

    if String.length(one_line_header) >= @one_line_header_cutoff do
      two_line_header
    else
      one_line_header
    end
  end

  defp last_module_name(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
  end

  defp type_defs(%Docs.Entry{metadata: %{opaque: true}} = entry) do
    Enum.map_join(entry.defs, "\n", fn def ->
      def
      |> String.split("::", parts: 2)
      |> List.first()
      |> String.trim()
    end)
  end

  defp type_defs(%Docs.Entry{} = entry) do
    Enum.join(entry.defs, "\n")
  end

  defp format_callbacks(callbacks) do
    callbacks
    |> Map.values()
    |> List.flatten()
    |> sort_entries()
    |> Enum.map_join("\n", fn %Docs.Entry{} = entry ->
      header =
        entry.defs
        |> Enum.map_join("\n", &("@callback " <> &1))
        |> Markdown.code_block()

      if is_binary(entry.doc) do
        """
        #{header}
        #{entry_doc_content(entry.doc)}
        """
      else
        header
      end
    end)
  end

  defp entry_doc_content(s) when is_binary(s), do: String.trim(s)
  defp entry_doc_content(_), do: nil

  defp sort_entries(entries) do
    Enum.sort_by(entries, &{&1.name, &1.arity})
  end

  defp empty?(empty) when empty in [nil, "", []], do: true
  defp empty?(_), do: false
end
