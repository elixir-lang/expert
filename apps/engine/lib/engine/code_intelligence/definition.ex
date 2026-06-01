defmodule Engine.CodeIntelligence.Definition do
  alias ElixirSense.Providers.Location, as: ElixirSenseLocation
  alias Engine.CodeIntelligence.Entity
  alias Engine.ManagerApi
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Location
  alias Forge.Document.Position
  alias Forge.Formats
  alias Forge.Search.Indexer.Entry
  alias Forge.Text
  alias Future.Code

  require Logger

  @spec definition(Document.t(), Position.t()) :: {:ok, [Location.t()]} | {:error, String.t()}
  def definition(%Document{} = document, %Position{} = position) do
    with {:ok, _, analysis} <- Document.Store.fetch(document.uri, :analysis),
         {:ok, entity, _range} <- Entity.resolve(analysis, position) do
      fetch_definition(entity, analysis, position)
    end
  end

  defp fetch_definition({type, entity} = resolved, %Analysis{} = analysis, %Position{} = position)
       when type in [:struct, :module] do
    module = Formats.module(entity)

    locations =
      module
      |> query_search_index(type: type, subtype: :definition)
      |> entries_to_locations()

    maybe_fallback_to_elixir_sense(resolved, locations, analysis, position)
  end

  defp fetch_definition(
         {:call, module, function, arity} = resolved,
         %Analysis{} = analysis,
         %Position{} = position
       ) do
    mfa = Formats.mfa(module, function, arity)

    definitions =
      mfa
      |> query_search_index(subtype: :definition)
      |> Stream.flat_map(fn entry ->
        case entry do
          %Entry{type: {:function, :delegate}} ->
            mfa = get_in(entry, [:metadata, :original_mfa])
            query_search_index(mfa, subtype: :definition) ++ [entry]

          _ ->
            [entry]
        end
      end)
      |> collapse_function_clauses()

    locations = entries_to_locations(definitions)

    maybe_fallback_to_elixir_sense(resolved, locations, analysis, position)
  end

  defp fetch_definition(_, %Analysis{} = analysis, %Position{} = position) do
    elixir_sense_definition(analysis, position)
  end

  defp maybe_fallback_to_elixir_sense(resolved, locations, analysis, position) do
    case locations do
      [] ->
        Logger.info("No definition found for #{inspect(resolved)} with Indexer.")

        analysis = Engine.CodeIntelligence.Heex.maybe_normalize(analysis, position)
        elixir_sense_definition(analysis, position)

      [location] ->
        {:ok, location}

      _ ->
        {:ok, locations}
    end
  end

  defp collapse_function_clauses(entries) do
    entries
    |> Enum.group_by(&function_definition_key/1)
    |> Enum.flat_map(fn
      {nil, entries} -> entries
      {_key, entries} -> [first_definition_entry(entries)]
    end)
  end

  defp function_definition_key(%Entry{
         path: path,
         subject: subject,
         subtype: :definition,
         type: {kind, _} = type
       })
       when kind in [:function, :macro] do
    {path, subject, type}
  end

  defp function_definition_key(_entry), do: nil

  defp first_definition_entry(entries) do
    Enum.min_by(entries, &definition_sort_key/1)
  end

  defp definition_sort_key(%Entry{range: %{start: start}, id: id}) do
    {start.line, start.character, id || 0}
  end

  defp definition_sort_key(%Entry{id: id}), do: {0, 0, id || 0}

  defp elixir_sense_definition(%Analysis{} = analysis, %Position{} = position) do
    analysis.document
    |> Document.to_string()
    |> ElixirSense.definition(position.line, position.character)
    |> parse_location(analysis.document)
  end

  defp parse_location(%ElixirSenseLocation{} = location, document) do
    %{file: file, line: line, column: column, type: type} = location
    file_path = file || document.path
    uri = Document.Path.ensure_uri(file_path)

    with {:ok, document} <- Document.Store.open_temporary(uri),
         {:ok, text} <- Document.fetch_text_at(document, line) do
      {line, column} = maybe_move_cursor_to_next_token(type, document, line, column)
      range = to_precise_range(document, text, line, column)
      {:ok, Location.new(range, document)}
    else
      _ ->
        {:error, "Could not open source file or fetch line text: #{inspect(file_path)}"}
    end
  end

  defp parse_location(nil, _) do
    {:ok, nil}
  end

  defp maybe_move_cursor_to_next_token(type, document, line, column)
       when type in [:function, :module, :macro] do
    position = Position.new(document, line, column)

    with {:ok, zipper} <- Ast.zipper_at(document, position),
         %{node: {entity_name, meta, _}} <- Sourceror.Zipper.next(zipper) do
      meta =
        if entity_name == :when do
          %{node: {_entity_name, meta, _}} = Sourceror.Zipper.next(zipper)
          meta
        else
          meta
        end

      {meta[:line], meta[:column]}
    else
      _ ->
        {line, column}
    end
  end

  defp maybe_move_cursor_to_next_token(_, _, line, column), do: {line, column}

  defp to_precise_range(%Document{} = document, text, line, column) do
    case Code.Fragment.surround_context(text, {line, column}) do
      %{begin: start_pos, end: end_pos} ->
        Entity.to_range(document, start_pos, end_pos)

      _ ->
        # If the column is 1, but the code doesn't start on the first column, which isn't what we want.
        # The cursor will be placed to the left of the actual definition.
        column = if column == 1, do: Text.count_leading_spaces(text) + 1, else: column
        pos = {line, column}
        Entity.to_range(document, pos, pos)
    end
  end

  defp entries_to_locations(entries) do
    Enum.flat_map(entries, fn entry ->
      case to_location(entry) do
        {:ok, location} -> [location]
        :error -> []
      end
    end)
  end

  defp to_location(entry) do
    uri = Document.Path.ensure_uri(entry.path)

    case Document.Store.open_temporary(uri) do
      {:ok, document} ->
        {:ok, Location.new(entry.range, document)}

      _ ->
        :error
    end
  end

  defp query_search_index(subject, condition) do
    case ManagerApi.search_store_exact(Engine.get_project(), subject, condition) do
      {:ok, entries} ->
        entries

      _ ->
        []
    end
  end
end
