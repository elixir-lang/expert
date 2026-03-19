defmodule Engine.CodeMod.Rename.Function do
  @moduledoc """
  Handles function renaming using the search index for locating all definitions
  and references, and text-based edits for performing the rename.
  """
  alias Engine.CodeIntelligence.Entity
  alias Engine.CodeMod.Rename.Entry, as: RenameEntry
  alias Engine.Search.Store
  alias Engine.Search.Subject
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Edit
  alias Forge.Document.Line
  alias Forge.Document.Position
  alias Forge.Document.Range

  import Line

  @spec recognizes?(Analysis.t(), Position.t()) :: boolean()
  def recognizes?(%Analysis{} = analysis, %Position{} = position) do
    case resolve(analysis, position) do
      {:ok, _, _} -> true
      _ -> false
    end
  end

  @spec prepare(Analysis.t(), Position.t()) ::
          {:ok, {:function, {atom(), atom(), non_neg_integer()}}, Range.t()}
          | {:error, term()}
  def prepare(%Analysis{} = analysis, %Position{} = position) do
    resolve(analysis, position)
  end

  @spec rename(Range.t(), String.t(), {atom(), atom(), non_neg_integer()}) ::
          [Document.Changes.t()]
  def rename(%Range{} = _range, new_name, {module, fun_name, arity}) do
    subject_prefix = Subject.mfa(module, fun_name, arity)

    case Store.prefix(subject_prefix, type: {:function, :_}) do
      {:ok, entries} ->
        entries
        |> Enum.map(&RenameEntry.new/1)
        |> Enum.group_by(&Document.Path.ensure_uri(&1.path))
        |> Enum.flat_map(fn {uri, file_entries} ->
          rename_file(uri, file_entries, fun_name, new_name)
        end)

      _ ->
        []
    end
  end

  defp resolve(%Analysis{} = analysis, %Position{} = position) do
    with {:ok, {:call, module, fun_name, arity}, range}
         when not is_nil(module) <- Entity.resolve(analysis, position) do
      {:ok, {:function, {module, fun_name, arity}}, range}
    else
      _ -> {:error, :not_a_renamable_function}
    end
  end

  defp rename_file(uri, entries, fun_name, new_name) do
    with {:ok, document} <- Document.Store.open_temporary(uri) do
      edits =
        entries
        |> Enum.map(&compute_function_name_range(&1, fun_name))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Edit.new(new_name, &1))

      if edits == [] do
        []
      else
        [Document.Changes.new(document, edits)]
      end
    else
      _ -> []
    end
  end

  defp compute_function_name_range(%RenameEntry{} = entry, fun_name) do
    fun_name_str = Atom.to_string(fun_name)
    fun_name_length = String.length(fun_name_str)
    line(text: text) = entry.range.start.context_line

    if text do
      line_text_from_start =
        String.slice(text, entry.range.start.character - 1, String.length(text))

      case find_function_name_offset(line_text_from_start, fun_name_str) do
        nil ->
          nil

        offset ->
          start_character = entry.range.start.character + offset
          end_character = start_character + fun_name_length

          Range.new(
            %{entry.range.start | character: start_character},
            %{entry.range.start | character: end_character}
          )
      end
    else
      nil
    end
  end

  defp find_function_name_offset(text_from_range_start, fun_name_str) do
    case :binary.match(text_from_range_start, ".#{fun_name_str}") do
      {pos, _len} ->
        pos + 1

      :nomatch ->
        if String.starts_with?(text_from_range_start, fun_name_str) do
          0
        else
          case :binary.match(text_from_range_start, " #{fun_name_str}") do
            {pos, _len} -> pos + 1
            :nomatch -> nil
          end
        end
    end
  end
end
