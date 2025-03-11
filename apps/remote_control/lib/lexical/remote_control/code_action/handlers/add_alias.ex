defmodule Lexical.RemoteControl.CodeAction.Handlers.AddAlias do
  alias Lexical.Ast
  alias Lexical.Ast.Analysis
  alias Lexical.Ast.Analysis.Alias
  alias Lexical.Document
  alias Lexical.Document.Changes
  alias Lexical.Document.Position
  alias Lexical.Document.Range
  alias Lexical.Formats
  alias Lexical.RemoteControl
  alias Lexical.RemoteControl.Analyzer
  alias Lexical.RemoteControl.CodeAction
  alias Lexical.RemoteControl.CodeIntelligence.Entity
  alias Lexical.RemoteControl.CodeMod
  alias Lexical.RemoteControl.Modules
  alias Lexical.RemoteControl.Search.Fuzzy
  alias Lexical.RemoteControl.Search.Indexer.Entry
  alias Mix.Tasks.Namespace
  alias Sourceror.Zipper

  @behaviour CodeAction.Handler

  @impl CodeAction.Handler
  def actions(%Document{} = doc, %Range{} = range, _diagnostics) do
    with {:ok, _doc, %Analysis{valid?: true} = analysis} <-
           Document.Store.fetch(doc.uri, :analysis),
         {:ok, resolved, _} <- Entity.resolve(analysis, range.start),
         {:ok, unaliased_module} <- fetch_unaliased_module(analysis, range.start, resolved) do
      current_aliases = CodeMod.Aliases.in_scope(analysis, range)

      unaliased_module
      |> possible_aliases()
      |> filter_by_resolution(resolved)
      |> Stream.map(&build_code_action(analysis, range, current_aliases, &1))
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  @impl CodeAction.Handler
  def kinds, do: [:quick_fix]

  @impl CodeAction.Handler
  def trigger_kind, do: :all

  defp build_code_action(%Analysis{} = analysis, range, current_aliases, potential_alias_module) do
    case Ast.Module.safe_split(potential_alias_module, as: :atoms) do
      {:erlang, _} ->
        nil

      {:elixir, segments} ->
        {insert_position, trailer} = CodeMod.Aliases.insert_position(analysis, range.start)
        alias_to_add = %Alias{module: segments, as: List.last(segments), explicit?: true}
        replace_current_alias = get_current_replacement(analysis, range, segments)

        alias_edits =
          CodeMod.Aliases.to_edits(
            [alias_to_add | current_aliases],
            insert_position,
            trailer
          )

        changes = Changes.new(analysis.document, replace_current_alias ++ alias_edits)

        CodeAction.new(
          analysis.document.uri,
          "alias #{Formats.module(potential_alias_module)}",
          :quick_fix,
          changes
        )
    end
  end

  def fetch_unaliased_module(%Analysis{} = analysis, %Position{} = position, resolved) do
    with {:ok, module} <- fetch_module(resolved),
         %{} = aliases <- Analyzer.aliases_at(analysis, position),
         false <- module in Map.values(aliases) do
      {:ok, module}
    else
      _ ->
        :error
    end
  end

  defp fetch_module({:module, module}), do: {:ok, module}
  defp fetch_module({:struct, module}), do: {:ok, module}
  defp fetch_module({:call, module, _function, _arity}), do: {:ok, module}
  defp fetch_module(_), do: :error

  defp get_current_replacement(%Analysis{} = analysis, %Range{} = range, segments) do
    with {:ok, patches} <- replace_full_module_on_line(analysis, range.start.line, segments),
         {:ok, edits} <- Ast.patches_to_edits(analysis.document, patches) do
      edits
    else
      _ ->
        []
    end
  end

  defp replace_full_module_on_line(%Analysis{} = analysis, line, segments) do
    aliased_module =
      segments
      |> List.last()
      |> List.wrap()
      |> Module.concat()
      |> Formats.module()

    analysis.document
    |> Ast.traverse_line(line, [], fn
      %Zipper{node: {:__aliases__, _, ^segments}} = zipper, patches ->
        range = Sourceror.get_range(zipper.node)

        patch = %{range: range, change: aliased_module}
        {zipper, [patch | patches]}

      zipper, acc ->
        {zipper, acc}
    end)
    |> case do
      {:ok, _, patches} -> {:ok, patches}
      error -> error
    end
  end

  @similarity_threshold 0.75
  defp similar?(a, b), do: String.jaro_distance(a, b) >= @similarity_threshold

  defp filter_by_resolution(modules_stream, {:call, _module, function, _arity}) do
    query_function = Atom.to_string(function)

    Stream.filter(modules_stream, fn module ->
      case Modules.fetch_functions(module) do
        {:ok, functions} ->
          Enum.any?(functions, fn {name, _arity} ->
            module_function = Atom.to_string(name)
            similar?(module_function, query_function)
          end)

        _ ->
          false
      end
    end)
  end

  defp filter_by_resolution(modules_stream, {:struct, _}) do
    Stream.filter(modules_stream, fn module ->
      case Modules.fetch_functions(module) do
        {:ok, functions} -> Keyword.has_key?(functions, :__struct__)
        _ -> false
      end
    end)
  end

  defp filter_by_resolution(modules_stream, _) do
    modules_stream
  end

  def possible_aliases(unaliased_module) do
    module_subject = Formats.module(unaliased_module)

    case Ast.Module.safe_split(unaliased_module) do
      {:elixir, unaliased_strings} ->
        module_subject
        |> do_fuzzy_search()
        |> Stream.filter(fn module ->
          {:elixir, split} = Ast.Module.safe_split(module)
          alias_as = List.last(split)
          subject_module = module
          RemoteControl.Module.Loader.ensure_loaded(subject_module)

          protocol_or_implementation? = function_exported?(module, :__impl__, 1)

          not protocol_or_implementation? and
            Enum.any?(unaliased_strings, &similar?(&1, alias_as))
        end)

      _ ->
        []
    end
  end

  defp do_fuzzy_search(subject) do
    # Note: we can't use the indexer's fuzzy matcher here, since it
    # ignores all deps, and then we won't be able to alias any deps module

    for {mod, _, _} <- all_modules(),
        elixir_module?(mod),
        not Namespace.Module.prefixed?(mod) do
      module_name = List.to_atom(mod)

      %Entry{
        id: module_name,
        path: "",
        subject: module_name,
        subtype: :definition,
        type: :module
      }
    end
    |> Fuzzy.from_entries()
    |> Fuzzy.match(subject)
  end

  defp all_modules do
    # Note: this is for testing
    :code.all_available()
  end

  defp elixir_module?([?E, ?l, ?i, ?x, ?i, ?r, ?. | _]), do: true
  defp elixir_module?(_), do: false
end
