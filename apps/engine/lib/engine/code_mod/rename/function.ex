defmodule Engine.CodeMod.Rename.Function do
  @moduledoc """
  Handles function renaming using the search index for locating all definitions
  and references, and text-based edits for performing the rename.
  """
  import Forge.Document.Line

  alias Engine.CodeIntelligence.Entity
  alias Engine.Search.Indexer.Quoted
  alias Engine.Search.Store
  alias Engine.Search.Subject
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Edit
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @spec recognizes?(Analysis.t(), Position.t()) :: boolean()
  def recognizes?(%Analysis{} = analysis, %Position{} = position) do
    match?({:ok, _, _}, resolve(analysis, position))
  end

  @spec prepare(Analysis.t(), Position.t()) ::
          {:ok, {:function, {module(), atom(), arity()}}, Range.t()}
          | {:error, :cannot_rename_function}
  def prepare(%Analysis{} = analysis, %Position{} = position) do
    resolve(analysis, position)
  end

  @spec rename(String.t(), {module(), atom(), arity()}) ::
          [Document.Changes.t()]
  def rename(new_name, {module, fun_name, arity}) do
    case rename_scope(module, fun_name, arity) do
      {:ok, scope} ->
        scope.paths
        |> Enum.flat_map(&rename_file(&1, scope, fun_name, new_name))

      :error ->
        []
    end
  end

  defp resolve(%Analysis{} = analysis, %Position{} = position) do
    with {:ok, {:call, module, fun_name, arity}, range} <- Entity.resolve(analysis, position),
         false <- is_nil(module),
         true <- can_rename?(module, fun_name, arity) do
      {:ok, {:function, {module, fun_name, arity}}, range}
    else
      _ ->
        {:error, :cannot_rename_function}
    end
  end

  defp rename_scope(module, fun_name, arity) do
    target_subject = Subject.mfa(module, fun_name, arity)
    function_prefix = Subject.mfa(module, fun_name, "")

    definitions =
      function_prefix
      |> prefix_entries(type: {:function, :_}, subtype: :definition)
      |> Enum.filter(&(function_entry?(&1) and String.starts_with?(&1.subject, function_prefix)))

    target_definition_keys =
      definitions
      |> Enum.filter(&(&1.subject == target_subject and owned_entry?(&1)))
      |> MapSet.new(&definition_key/1)

    if MapSet.size(target_definition_keys) == 0 do
      :error
    else
      subjects =
        definitions
        |> Enum.filter(&MapSet.member?(target_definition_keys, definition_key(&1)))
        |> Enum.map(& &1.subject)
        |> then(&[target_subject | &1])
        |> MapSet.new()

      paths =
        subjects
        |> Enum.flat_map(&exact_entries(&1, type: {:function, :_}))
        |> Enum.filter(
          &(function_entry?(&1) and MapSet.member?(subjects, &1.subject) and owned_entry?(&1))
        )
        |> Enum.uniq_by(& &1.path)
        |> Enum.map(& &1.path)

      {:ok, %{subjects: subjects, paths: paths}}
    end
  end

  defp can_rename?(module, fun_name, arity) do
    match?({:ok, %{paths: [_ | _]}}, rename_scope(module, fun_name, arity))
  end

  defp rename_file(path, scope, fun_name, new_name) do
    uri = Document.Path.ensure_uri(path)

    with {:ok, document} <- Document.Store.open_temporary(uri),
         %Analysis{valid?: true} = analysis <- Ast.analyze(document),
         {:ok, entries} <- Quoted.index(analysis) do
      edits =
        entries
        |> Enum.filter(&(function_entry?(&1) and MapSet.member?(scope.subjects, &1.subject)))
        |> Enum.map(&function_name_range(document, &1, fun_name))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(&range_key/1)
        |> Enum.sort_by(&range_key/1, :desc)
        |> Enum.map(&Edit.new(new_name, &1))

      if edits == [] do
        []
      else
        [Document.Changes.new(document, edits)]
      end
    else
      _ ->
        []
    end
  end

  defp function_name_range(%Document{} = document, %Entry{} = entry, fun_name) do
    fun_name_str = Atom.to_string(fun_name)
    fun_name_length = String.length(fun_name_str)

    entry
    |> candidate_name_ranges(fun_name_str, fun_name_length)
    |> Enum.find(fn %Range{} = range ->
      Document.fragment(document, range.start, range.end) == fun_name_str
    end)
  end

  defp candidate_name_ranges(
         %Entry{range: %Range{} = range},
         fun_name_str,
         fun_name_length
       ) do
    %Range{start: start_position} = range
    context_line = start_position.context_line

    case context_line do
      nil ->
        []

      line(text: nil) ->
        []

      line(text: text) ->
        text
        |> String.slice(start_position.character - 1, String.length(text))
        |> find_function_name_offsets(fun_name_str)
        |> Enum.map(fn offset ->
          start_character = start_position.character + offset
          end_character = start_character + fun_name_length

          Range.new(
            %{start_position | character: start_character},
            %{start_position | character: end_character}
          )
        end)
    end
  end

  defp find_function_name_offsets(text_from_range_start, fun_name_str) do
    pattern = ~r/(?<![A-Za-z0-9_])#{Regex.escape(fun_name_str)}(?![A-Za-z0-9_!?])/

    pattern
    |> Regex.scan(text_from_range_start, return: :index)
    |> Enum.map(fn [{pos, _len} | _] -> pos end)
  end

  defp exact_entries(subject, constraints) do
    case Store.exact(subject, constraints) do
      {:ok, entries} ->
        entries

      _ ->
        []
    end
  end

  defp prefix_entries(prefix, constraints) do
    case Store.prefix(prefix, constraints) do
      {:ok, entries} -> entries
      _ -> []
    end
  end

  defp function_entry?(%Entry{type: {:function, _}}), do: true
  defp function_entry?(_), do: false

  defp owned_entry?(%Entry{path: path}) do
    case Engine.get_project() do
      %Project{root_uri: uri} = project when not is_nil(uri) ->
        Project.owns_path?(project, Document.Path.ensure_path(path))

      _ ->
        true
    end
  end

  defp definition_key(%Entry{} = entry) do
    {Document.Path.ensure_path(entry.path), range_key(entry.range)}
  end

  defp range_key(%Range{} = range) do
    {
      range.start.line,
      range.start.character,
      range.end.line,
      range.end.character
    }
  end
end
