defmodule Engine.CodeMod.Rename.Module do
  @moduledoc """
  Handles module renaming logic.

  This module is responsible for:
  - Recognizing if a position is at a module definition
  - Preparing the rename range
  - Executing the rename across all references
  """
  alias Engine.CodeIntelligence.Entity
  alias Engine.CodeMod.Rename
  alias Engine.CodeMod.Rename.Entry
  alias Engine.CodeMod.Rename.Module
  alias Engine.Search.Store
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Edit
  alias Forge.Document.Line
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Formats

  require Logger
  import Line

  @doc """
  Checks if the position is at a module that can be renamed.
  """
  @spec recognizes?(Analysis.t(), Position.t()) :: boolean()
  def recognizes?(%Analysis{} = analysis, %Position{} = position) do
    case resolve(analysis, position) do
      {:ok, _, _} ->
        true

      _ ->
        false
    end
  end

  @doc """
  Prepares the rename operation by returning the module and the range to be renamed.
  """
  @spec prepare(Analysis.t(), Position.t()) ::
          {:ok, {:module, atom()}, Range.t()} | {:error, tuple() | atom()}
  def prepare(%Analysis{} = analysis, %Position{} = position) do
    with {:ok, {:module, _module}, _range} <- resolve(analysis, position) do
      {module, range} = surround_the_whole_module(analysis, position)

      if cursor_at_declaration?(module, range) do
        {:ok, {:module, module}, range}
      else
        {:error, {:unsupported_location, :module}}
      end
    end
  end

  @doc """
  Executes the rename operation, returning a list of document changes.
  """
  @spec rename(Range.t(), String.t(), atom()) :: [Document.Changes.t()]
  def rename(%Range{} = old_range, new_name, module) do
    {to_be_renamed, replacement} = old_range |> range_text() |> Module.Diff.diff(new_name)
    results = exacts(module, to_be_renamed) ++ descendants(module, to_be_renamed)

    for {uri, entries} <- Enum.group_by(results, &Document.Path.ensure_uri(&1.path)),
        result = to_document_changes(uri, entries, replacement),
        match?({:ok, _}, result) do
      {:ok, document_changes} = result
      document_changes
    end
  end

  defp resolve(%Analysis{} = analysis, %Position{} = position) do
    case Entity.resolve(analysis, position) do
      {:ok, {module_or_struct, module}, range} when module_or_struct in [:struct, :module] ->
        {:ok, {:module, module}, range}

      _ ->
        {:error, :not_a_module}
    end
  end

  defp resolve(path, %Position{} = position) do
    uri = Document.Path.ensure_uri(path)

    with {:ok, _} <- Document.Store.open_temporary(uri),
         {:ok, _document, analysis} <- Document.Store.fetch(uri, :analysis) do
      resolve(analysis, position)
    end
  end

  defp cursor_at_declaration?(module, rename_range) do
    case Store.exact(module, type: :module, subtype: :definition) do
      {:ok, [definition]} ->
        rename_range == definition.range

      _ ->
        false
    end
  end

  defp surround_the_whole_module(analysis, position) do
    # When renaming occurs, we want users to be able to choose any place in the defining module,
    # not just the last local module, like: `defmodule |Foo.Bar do` also works.
    {:ok, %{end: {_end_line, end_character}}} = Ast.surround_context(analysis, position)
    end_position = %{position | character: end_character - 1}
    {:ok, {:module, module}, range} = resolve(analysis, end_position)
    {module, range}
  end

  defp exacts(module, to_be_renamed) do
    module
    |> query_for_exacts()
    |> Enum.filter(&entry_matching?(&1, to_be_renamed))
    |> adjust_range_for_exacts(to_be_renamed)
  end

  defp descendants(module, to_be_renamed) do
    module
    |> query_for_descendants()
    |> Enum.filter(&(entry_matching?(&1, to_be_renamed) and has_dots_in_range?(&1)))
    |> adjust_range_for_descendants(module, to_be_renamed)
  end

  defp query_for_exacts(module) do
    module_string = Formats.module(module)

    case Store.exact(module_string, type: :module) do
      {:ok, entries} -> Enum.map(entries, &Entry.new/1)
      {:error, _} -> []
    end
  end

  defp query_for_descendants(module) do
    module_string = Formats.module(module)
    prefix = "#{module_string}."

    case Store.prefix(prefix, type: :module) do
      {:ok, entries} -> Enum.map(entries, &Entry.new/1)
      {:error, _} -> []
    end
  end

  defp maybe_rename_file(document, entries, replacement) do
    entries
    |> Enum.map(&Rename.File.maybe_rename(document, &1, replacement))
    # every group should have only one `rename_file`
    |> Enum.find(&(not is_nil(&1)))
  end

  defp entry_matching?(entry, to_be_renamed) do
    entry.range |> range_text() |> String.contains?(to_be_renamed)
  end

  defp has_dots_in_range?(entry) do
    entry.range |> range_text() |> String.contains?(".")
  end

  defp adjust_range_for_exacts(entries, to_be_renamed) do
    old_suffix_length = String.length(to_be_renamed)

    for %Entry{} = entry <- entries do
      start_character = entry.edit_range.end.character - old_suffix_length
      put_in(entry.edit_range.start.character, start_character)
    end
  end

  defp adjust_range_for_descendants(entries, module, to_be_renamed) do
    for %Entry{} = entry <- entries,
        range_text = range_text(entry.edit_range),
        matches = matches(range_text, to_be_renamed),
        result = resolve_module_range(entry, module, matches),
        match?({:ok, _}, result) do
      {_, range} = result
      %{entry | edit_range: range}
    end
  end

  defp range_text(range) do
    line(text: text) = range.end.context_line
    String.slice(text, range.start.character - 1, range.end.character - range.start.character)
  end

  defp resolve_module_range(_entry, _module, []) do
    {:error, :not_found}
  end

  defp resolve_module_range(entry, module, [[{start, length}]]) do
    range = adjust_range_characters(entry.edit_range, {start, length})

    with {:ok, {:module, ^module}, _} <- resolve(entry.path, range.end) do
      {:ok, range}
    end
  end

  defp resolve_module_range(entry, module, [[{start, length}] | tail] = _matches) do
    # This function is mainly for the duplicated suffixes
    # For example, if we have a module named `Foo.Bar.Foo.Bar` and we want to rename it to `Foo.Bar.Baz`
    # The `Foo.Bar` will be duplicated in the range text, so we need to resolve the correct range
    # and only rename the second occurrence of `Foo.Bar`
    start_character = entry.edit_range.start.character + start
    position = %{entry.edit_range.start | character: start_character}

    with {:ok, {:module, result}, range} <- resolve(entry.path, position) do
      if result == module do
        range = adjust_range_characters(range, {start, length})
        {:ok, range}
      else
        resolve_module_range(entry, module, tail)
      end
    end
  end

  defp matches(range_text, "") do
    # When expanding a module, the to_be_renamed is an empty string,
    # so we need to scan the module before the period
    for [{start, length}] <- Regex.scan(~r/\w+(?=\.)/, range_text, return: :index) do
      [{start + length, 0}]
    end
  end

  defp matches(range_text, to_be_renamed) do
    Regex.scan(~r/#{to_be_renamed}/, range_text, return: :index)
  end

  defp adjust_range_characters(%Range{} = range, {start, length} = _matched_old_suffix) do
    start_character = range.start.character + start
    end_character = start_character + length

    range
    |> put_in([:start, :character], start_character)
    |> put_in([:end, :character], end_character)
  end

  defp to_document_changes(uri, entries, replacement) do
    with {:ok, document} <- Document.Store.open_temporary(uri) do
      rename_file = maybe_rename_file(document, entries, replacement)

      edits =
        Enum.map(entries, fn entry ->
          reference? = entry.subtype == :reference

          if reference? and not ancestor_is_alias?(document, entry.edit_range.start) do
            replacement = replacement |> String.split(".") |> Enum.at(-1)
            Edit.new(replacement, entry.edit_range)
          else
            Edit.new(replacement, entry.edit_range)
          end
        end)

      {:ok, Document.Changes.new(document, edits, rename_file)}
    end
  end

  defp ancestor_is_alias?(%Document{} = document, %Position{} = position) do
    document
    |> Ast.cursor_path(position)
    |> Enum.any?(&match?({:alias, _, _}, &1))
  end
end
