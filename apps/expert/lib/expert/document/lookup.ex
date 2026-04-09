defmodule Expert.Document.Lookup do
  @moduledoc """
  Resolves a document URI or `%Document{}` into a `%Document.Context{}`.
  """

  alias Expert.Document.Context
  alias Forge.Document
  alias Forge.Project

  @doc """
  Resolves a URI or `%Document{}` into a `%Document.Context{}`.
  """
  @spec resolve(Forge.uri() | Document.t(), [Project.t()]) :: Context.t()
  def resolve(uri_or_document, projects)

  def resolve(uri, projects) when is_binary(uri) and is_list(projects) do
    case Document.Store.fetch(uri) do
      {:ok, %Document{} = document} ->
        project = project_for_path(projects, document.path)
        context_for(uri, document, project)

      _ ->
        project = project_for_uri(projects, uri)
        context_for(uri, nil, project)
    end
  end

  def resolve(%Document{} = document, projects) when is_list(projects) do
    project = project_for_path(projects, document.path)
    context_for(document.uri, document, project)
  end

  @doc """
  Resolves an LSP request or notification struct into a `%Document.Context{}`.
  """
  @spec resolve_from_request(struct(), [Project.t()]) :: Context.t()
  def resolve_from_request(request_or_params, projects) when is_list(projects) do
    case extract_uri(request_or_params) do
      uri when is_binary(uri) ->
        resolve(uri, projects)

      nil ->
        case Document.Container.context_document(request_or_params, nil) do
          %Document{} = document -> resolve(document, projects)
          nil -> Context.bare(nil, nil)
        end
    end
  end

  @doc """
  Finds the project root URI for a document URI.
  """
  @spec find_project_root_uri(Forge.uri()) :: Forge.uri() | nil
  def find_project_root_uri(uri) when is_binary(uri) do
    path =
      uri
      |> Document.Path.from_uri()
      |> Path.expand()
      |> path_or_parent_dir()

    boundary = workspace_boundary_path(path)

    case traverse_path(Path.split(path), boundary) do
      nil -> nil
      root_path -> Document.Path.to_uri(root_path)
    end
  end

  defp project_for_uri(projects, uri) when is_list(projects) and is_binary(uri) do
    path = Document.Path.from_uri(uri)
    project_for_path(projects, path)
  end

  defp context_for(uri, document, %Project{} = project) do
    Context.project(uri, document, project)
  end

  defp context_for(uri, document, nil) do
    Context.bare(uri, document)
  end

  defp project_for_path(projects, path) do
    projects
    |> Enum.filter(fn project -> Forge.Path.parent_path?(path, Project.root_path(project)) end)
    |> Enum.max_by(fn project -> byte_size(Project.root_path(project)) end, fn -> nil end)
  end

  defp traverse_path([], _boundary), do: nil

  defp traverse_path(segments, boundary) do
    path = Path.join(segments)
    mix_exs_path = Path.join(path, "mix.exs")

    cond do
      boundary_reached?(path, boundary) ->
        nil

      File.exists?(mix_exs_path) ->
        umbrella_root_for(path, boundary) || path

      true ->
        {_last, rest} = List.pop_at(segments, -1)
        traverse_path(rest, boundary)
    end
  end

  defp workspace_boundary_path(document_path) do
    case Forge.Workspace.get_workspace() do
      %Forge.Workspace{root_path: root_path} when is_binary(root_path) ->
        Path.expand(root_path)

      %Forge.Workspace{workspace_folders: workspace_folders} ->
        workspace_folder_boundary_path(document_path, workspace_folders)

      _ ->
        nil
    end
  end

  defp workspace_folder_boundary_path(document_path, workspace_folders) do
    document_path = Path.expand(document_path)

    workspace_folders
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(&Forge.Path.parent_path?(document_path, &1))
    |> Enum.max_by(&byte_size/1, fn -> nil end)
  end

  defp boundary_reached?(_path, nil), do: false

  defp boundary_reached?(path, boundary) do
    expanded_path = Path.expand(path)
    not Forge.Path.parent_path?(expanded_path, boundary)
  end

  defp path_or_parent_dir(path) do
    if File.dir?(path) do
      path
    else
      Path.dirname(path)
    end
  end

  defp umbrella_root_for(project_path, boundary) do
    project_path = Path.expand(project_path)
    find_umbrella_root(Path.dirname(project_path), project_path, boundary)
  end

  defp find_umbrella_root(nil, _project_path, _boundary), do: nil

  defp find_umbrella_root(current_path, project_path, boundary) do
    if !boundary_reached?(current_path, boundary) do
      case umbrella_apps_path(current_path) do
        apps_path when is_binary(apps_path) ->
          apps_root = Path.expand(Path.join(current_path, apps_path))

          if project_path == apps_root or Forge.Path.parent_path?(project_path, apps_root) do
            current_path
          else
            find_umbrella_root(next_parent(current_path), project_path, boundary)
          end

        _ ->
          find_umbrella_root(next_parent(current_path), project_path, boundary)
      end
    end
  end

  defp next_parent(path) do
    parent = Path.dirname(path)

    if parent != path do
      parent
    end
  end

  defp umbrella_apps_path(project_path) when is_binary(project_path) do
    mix_exs_path = Path.join(project_path, "mix.exs")

    with true <- File.exists?(mix_exs_path),
         {:ok, source} <- File.read(mix_exs_path),
         {:ok, ast} <- Code.string_to_quoted(source),
         apps_path when is_binary(apps_path) <- extract_apps_path(ast) do
      apps_path
    else
      _ -> nil
    end
  end

  defp extract_apps_path(ast) do
    {_ast, apps_path} =
      Macro.prewalk(ast, nil, fn
        {:apps_path, value} = node, nil when is_binary(value) -> {node, value}
        node, acc -> {node, acc}
      end)

    apps_path
  end

  defp extract_uri(%{text_document: %{uri: uri}}) when is_binary(uri), do: uri
  defp extract_uri(%{uri: uri}) when is_binary(uri), do: uri
  defp extract_uri(%{params: params}) when is_map(params), do: extract_uri(params)
  defp extract_uri(_), do: nil
end
