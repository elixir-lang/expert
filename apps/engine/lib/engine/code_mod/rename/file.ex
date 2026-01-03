defmodule Engine.CodeMod.Rename.File do
  @moduledoc """
  Handles file renaming logic during module renaming operations.

  Determines if a file should be renamed when its containing module is renamed,
  based on conventions and constraints.
  """
  alias Engine.CodeMod.Rename.Entry
  alias Engine.Search.Indexer
  alias Forge.Ast
  alias Forge.Document
  alias Forge.ProcessCache
  alias Forge.Project
  alias Forge.Search.Indexer.Entry, as: IndexerEntry

  @doc """
  Determines if a file should be renamed when renaming a module.

  Returns a `Forge.Document.Changes.RenameFile` struct if the file should be renamed,
  or `nil` if no file rename is needed.
  """
  @spec maybe_rename(Document.t(), Entry.t(), String.t()) :: Document.Changes.RenameFile.t() | nil
  def maybe_rename(%Document{} = document, %Entry{} = entry, new_suffix) do
    if root_module?(entry, document) do
      rename_file(document, entry, new_suffix)
    end
  end

  defp root_module?(%Entry{} = entry, document) do
    entries =
      ProcessCache.trans("#{document.uri}-entries", 50, fn ->
        with {:ok, entries} <-
               Indexer.Source.index_document(document, [Indexer.Extractors.Module]) do
          entries
        end
      end)

    case Enum.filter(entries, &(&1.block_id == :root)) do
      [%IndexerEntry{} = root_module] ->
        root_module.subject == entry.subject and root_module.block_range == entry.block_range

      _ ->
        false
    end
  end

  defp rename_file(document, %Entry{} = entry, new_suffix) do
    root_path = root_path()
    relative_path = Path.relative_to(entry.path, root_path)

    with {:ok, prefix} <- fetch_conventional_prefix(relative_path),
         {:ok, new_name} <- fetch_new_name(document, entry, new_suffix) do
      extname = Path.extname(entry.path)

      suffix =
        new_name
        |> Macro.underscore()
        |> maybe_insert_special_phoenix_folder(entry.subject, relative_path)

      new_path = Path.join([root_path, prefix, "#{suffix}#{extname}"])
      new_uri = Document.Path.ensure_uri(new_path)

      if document.uri != new_uri do
        Document.Changes.RenameFile.new(document.uri, new_uri)
      end
    else
      _ -> nil
    end
  end

  defp root_path do
    Project.root_path(Engine.get_project())
  end

  defp fetch_new_name(document, %Entry{} = entry, new_suffix) do
    text_edits = [Document.Edit.new(new_suffix, entry.edit_range)]

    with {:ok, edited_document} <-
           Document.apply_content_changes(document, document.version + 1, text_edits),
         {:ok, %{context: {:alias, alias}}} <-
           Ast.surround_context(edited_document, entry.edit_range.start) do
      {:ok, to_string(alias)}
    else
      _ -> :error
    end
  end

  defp fetch_conventional_prefix(path) do
    # To obtain the new relative path, we can't directly convert from the *new module* name.
    # We also need a part of the prefix, and Elixir has some conventions in this regard,
    # For example:
    #
    # in umbrella projects, the prefix is `Path.join(["apps", app_name, "lib"])`
    # in non-umbrella projects, most file's prefix is `"lib"`
    #
    # ## Examples
    #
    # iex> fetch_conventional_prefix("apps/remote_control/lib/lexical/remote_control/code_mod/rename/file.ex")
    # {:ok, "apps/remote_control/lib"}
    segments =
      case Path.split(path) do
        ["apps", app_name, "lib" | _] -> ["apps", app_name, "lib"]
        ["apps", app_name, "test" | _] -> ["apps", app_name, "test"]
        ["lib" | _] -> ["lib"]
        ["test" | _] -> ["test"]
        _ -> nil
      end

    if segments do
      {:ok, Path.join(segments)}
    else
      :error
    end
  end

  defp maybe_insert_special_phoenix_folder(suffix, subject, relative_path) do
    insertions =
      cond do
        phoenix_controller_module?(subject) ->
          "controllers"

        phoenix_liveview_module?(subject) ->
          "live"

        phoenix_component_module?(subject) ->
          "components"

        true ->
          nil
      end

    # In some cases, users prefer to include the `insertions` in the module name,
    # such as `DemoWeb.Components.Icons`.
    # In this case, we should not insert the prefix in a nested manner.
    prefer_to_include_insertions? = insertions in Path.split(suffix)
    old_path_contains_insertions? = insertions in Path.split(relative_path)

    if not is_nil(insertions) and old_path_contains_insertions? and
         not prefer_to_include_insertions? do
      suffix
      |> Path.split()
      |> List.insert_at(1, insertions)
      |> Path.join()
    else
      suffix
    end
  end

  defp phoenix_controller_module?(module) do
    function_exists?(module, :call, 2) and function_exists?(module, :action, 2)
  end

  defp phoenix_liveview_module?(module) do
    function_exists?(module, :mount, 3) and function_exists?(module, :render, 1)
  end

  defp phoenix_component_module?(module) do
    function_exists?(module, :__components__, 0) or
      function_exists?(module, :__live__, 0)
  end

  defp function_exists?(module, function, arity) do
    function_exported?(module, function, arity)
  end
end
