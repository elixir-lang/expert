defmodule Engine.CodeMod.Format do
  import Forge.Logging

  alias Engine.Build
  alias Engine.CodeMod.Diff
  alias Engine.CodeMod.Format.Cache
  alias Forge.Document
  alias Forge.Document.Changes
  alias Forge.Project

  @type formatter_function :: (String.t() -> {:ok, String.t()} | {:error, Exception.t()}) | nil

  @spec edits(Document.t()) :: {:ok, Changes.t()} | {:error, any}
  def edits(%Document{} = document) do
    project = Engine.get_project()
    format_result = do_format(project, document)

    # Compiling first would make the format request wait on the Engine.Mix
    # lock for the compile it just scheduled; formatting runs first and the
    # compile keeps diagnostics fresh afterwards — including the syntax-error
    # diagnostics when formatting fails.
    Build.compile_document(project, document)

    with {:ok, formatted} <- format_result do
      edits = Diff.diff(document, formatted)
      {:ok, Changes.new(document, edits)}
    end
  end

  defp do_format(%Project{} = project, %Document{} = document) do
    project_path = Project.project_path(project)

    timed_log("format: format document", fn ->
      with :ok <- check_current_directory(document, project_path),
           {:ok, formatter} <- formatter_for(project, document) do
        apply_formatter(document, formatter)
      end
    end)
  end

  defp apply_formatter(%Document{} = document, formatter) do
    document
    |> Document.to_string()
    |> formatter.()
  end

  @spec formatter_for(Project.t(), Document.t()) :: {:ok, formatter_function} | {:error, term()}
  defp formatter_for(%Project{} = project, %Document{} = document) do
    case Cache.fetch_formatter(project, document.path) do
      {:ok, formatter_function, _opts} ->
        {:ok, formatter_function}

      :error ->
        {:error, :no_formatter}
    end
  end

  defp check_current_directory(%Document{} = document, project_path) do
    if subdirectory?(document.path, parent: project_path) do
      :ok
    else
      message =
        """
        Cannot format file #{document.path}.
        It is not in the project at #{project_path}
        """
        |> String.trim()

      {:error, message}
    end
  end

  defp subdirectory?(child, parent: parent) do
    Forge.Path.contains?(child, parent)
  end
end
