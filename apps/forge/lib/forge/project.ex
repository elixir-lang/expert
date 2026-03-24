defmodule Forge.Project do
  @moduledoc """
  The representation of the current state of an elixir project.

  This struct contains all the information required to build a project and interrogate its configuration,
  as well as business logic for how to change its attributes.
  """
  alias Forge.Document
  alias Forge.Internet

  require Logger

  defstruct root_uri: nil,
            mix_exs_uri: nil,
            mix_project?: false,
            mix_env: nil,
            mix_target: nil,
            env_variables: %{},
            project_module: nil,
            entropy: 1

  @type message :: String.t()
  @type restart_notification :: {:restart, Logger.level(), String.t()}
  @type t :: %__MODULE__{
          root_uri: Forge.uri() | nil,
          mix_exs_uri: Forge.uri() | nil,
          entropy: non_neg_integer(),
          mix_env: atom(),
          mix_target: atom(),
          env_variables: %{String.t() => String.t()}
        }
  @type error_with_message :: {:error, message}

  @workspace_directory_name ".expert"

  @spec new(Forge.uri()) :: t
  def new(root_uri) do
    entropy = :rand.uniform(65_536)

    %__MODULE__{entropy: entropy}
    |> maybe_set_root_uri(root_uri)
    |> maybe_set_mix_exs_uri()
  end

  @spec set_project_module(t(), module() | nil) :: t()
  def set_project_module(%__MODULE__{} = project, nil) do
    project
  end

  def set_project_module(%__MODULE__{} = project, module) when is_atom(module) do
    %__MODULE__{project | project_module: module}
  end

  @doc """
  Retrieves the name of the project
  """
  @spec name(t) :: String.t()

  def name(%__MODULE__{} = project) do
    folder_name(project)
  end

  @doc """
  Returns a unique name for the project, suitable for process registration.

  Appends a hash of the full root path to disambiguate projects that share
  the same folder name (e.g. an umbrella root and a sub-app within it).
  """
  @spec unique_name(t) :: String.t()
  def unique_name(%__MODULE__{} = project) do
    hash = :erlang.phash2(root_path(project))
    "#{name(project)}::#{hash}"
  end

  @doc """
  The project node's name
  """
  def node_name(%__MODULE__{} = project) do
    sanitized = Forge.Node.sanitize(name(project))
    :"expert-project-#{sanitized}-#{entropy(project)}@127.0.0.1"
  end

  def entropy(%__MODULE__{} = project) do
    project.entropy
  end

  def config(%__MODULE__{} = project) do
    config_key = {__MODULE__, name(project), :config}

    case :persistent_term.get(config_key, :not_found) do
      :not_found ->
        config = project.project_module.project()
        :persistent_term.put(config_key, config)
        config

      config ->
        config
    end
  end

  @doc """
  Returns the the name defined in the `project/0` of mix.exs file
  """
  def display_name(%__MODULE__{} = project) do
    case config(project) do
      [] ->
        folder_name(project)

      config ->
        Keyword.get(config, :name, folder_name(project))
    end
  end

  @doc """
  Retrieves the name of the project as an atom
  """
  @spec atom_name(t) :: atom
  def atom_name(%__MODULE__{project_module: nil} = project) do
    project
    |> name()
    |> String.to_atom()
  end

  def atom_name(%__MODULE__{} = project) do
    project.project_module
  end

  @doc """
  Returns the full path of the project's root directory
  """
  @spec root_path(t) :: Path.t() | nil
  def root_path(%__MODULE__{root_uri: nil}) do
    nil
  end

  def root_path(%__MODULE__{} = project) do
    Document.Path.from_uri(project.root_uri)
  end

  @spec project_path(t) :: Path.t() | nil
  def project_path(%__MODULE__{root_uri: nil}) do
    nil
  end

  def project_path(%__MODULE__{} = project) do
    Document.Path.from_uri(project.root_uri)
  end

  @doc """
  Returns the full path to the project's mix.exs file
  """
  @spec mix_exs_path(t) :: Path.t() | nil
  def mix_exs_path(%__MODULE__{mix_exs_uri: nil}) do
    nil
  end

  def mix_exs_path(%__MODULE__{mix_exs_uri: mix_exs_uri}) do
    Document.Path.from_uri(mix_exs_uri)
  end

  @spec change_environment_variables(t, map() | nil) ::
          {:ok, t} | error_with_message() | restart_notification()
  def change_environment_variables(%__MODULE__{} = project, environment_variables) do
    set_env_vars(project, environment_variables)
  end

  def manager_node_name(%__MODULE__{} = project) do
    workspace = Forge.Workspace.get_workspace()

    workspace_name =
      case workspace do
        nil -> name(project)
        _ -> Forge.Workspace.name(workspace)
      end

    sanitized = Forge.Node.sanitize(workspace_name)
    :"expert-manager-#{sanitized}-#{entropy(project)}@127.0.0.1"
  end

  @doc """
  Returns the full path to the project's expert workspace directory

  Expert maintains a workspace directory in project it knows about, and places various
  artifacts there. This function returns the full path to that directory
  """
  @spec workspace_path(t) :: String.t()
  def workspace_path(%__MODULE__{} = project) do
    project
    |> root_path()
    |> Path.join(@workspace_directory_name)
  end

  @doc """
  Returns the full path to a file in expert's workspace directory
  """
  @spec workspace_path(t, String.t() | [String.t()]) :: String.t()
  def workspace_path(%__MODULE__{} = project, relative_path) when is_binary(relative_path) do
    workspace_path(project, [relative_path])
  end

  def workspace_path(%__MODULE__{} = project, relative_path) when is_list(relative_path) do
    Path.join([workspace_path(project) | relative_path])
  end

  @doc """
  Returns the full path to the directory where expert puts build artifacts
  """
  def build_path(%__MODULE__{} = project) do
    project
    |> workspace_path()
    |> Path.join("build")
  end

  @doc """
  Returns the full path to the directory where expert puts versioned build artifacts
  """
  def versioned_build_path(%__MODULE__{} = project) do
    %{elixir: elixir, erlang: erlang} = Forge.VM.Versions.current()
    erlang_major = erlang |> String.split(".") |> List.first()
    elixir_version = Version.parse!(elixir)
    elixir_major = "#{elixir_version.major}.#{elixir_version.minor}"
    build_root = build_path(project)
    Path.join([build_root, "erl-#{erlang_major}", "elixir-#{elixir_major}"])
  end

  @doc """
  Returns the full path to the directory where expert puts engine archives
  """
  def engine_path(%__MODULE__{} = project) do
    project
    |> workspace_path()
    |> Path.join("engine")
  end

  @doc """
  Creates and initializes expert's workspace directory if it doesn't already exist
  """
  @spec ensure_workspace(t()) ::
          :ok | {:error, File.posix() | :badarg | :terminated | :system_limit}
  def ensure_workspace(%__MODULE__{} = project) do
    with :ok <- ensure_workspace_directory(project) do
      ensure_git_ignore(project)
    end
  end

  defp ensure_workspace_directory(project) do
    workspace_path = workspace_path(project)

    cond do
      File.exists?(workspace_path) and File.dir?(workspace_path) ->
        :ok

      File.exists?(workspace_path) ->
        :ok = File.rm(workspace_path)
        File.mkdir_p(workspace_path)

      true ->
        File.mkdir(workspace_path)
    end
  end

  defp ensure_git_ignore(project) do
    contents = """
    *
    """

    path = workspace_path(project, ".gitignore")

    if File.exists?(path) do
      :ok
    else
      File.write(path, contents)
    end
  end

  defp maybe_set_root_uri(%__MODULE__{} = project, nil),
    do: %__MODULE__{project | root_uri: nil}

  defp maybe_set_root_uri(%__MODULE__{} = project, "file://" <> _ = root_uri) do
    root_path =
      root_uri
      |> Document.Path.absolute_from_uri()
      |> Path.expand()

    if File.exists?(root_path) do
      expanded_uri = Document.Path.to_uri(root_path)
      %__MODULE__{project | root_uri: expanded_uri}
    else
      project
    end
  end

  defp maybe_set_mix_exs_uri(%__MODULE__{} = project) do
    possible_mix_exs_path =
      project
      |> root_path()
      |> find_mix_exs_path()

    if mix_exs_exists?(possible_mix_exs_path) do
      %__MODULE__{
        project
        | mix_exs_uri: Document.Path.to_uri(possible_mix_exs_path),
          mix_project?: true
      }
    else
      project
    end
  end

  # Project Path

  # Environment variables

  def set_env_vars(%__MODULE__{} = old_project, %{} = env_vars) do
    case {old_project.env_variables, env_vars} do
      {nil, vars} when map_size(vars) == 0 ->
        {:ok, %__MODULE__{old_project | env_variables: vars}}

      {nil, new_vars} ->
        System.put_env(new_vars)
        {:ok, %__MODULE__{old_project | env_variables: new_vars}}

      {same, same} ->
        {:ok, old_project}

      _ ->
        {:restart, :warning, "Environment variables have changed. Expert needs to restart"}
    end
  end

  def set_env_vars(%__MODULE__{} = old_project, _) do
    {:ok, old_project}
  end

  defp find_mix_exs_path(nil) do
    System.get_env("MIX_EXS")
  end

  defp find_mix_exs_path(project_directory) do
    case System.get_env("MIX_EXS") do
      nil ->
        Path.join(project_directory, "mix.exs")

      mix_exs ->
        mix_exs
    end
  end

  defp mix_exs_exists?(nil), do: false

  defp mix_exs_exists?(mix_exs_path) do
    File.exists?(mix_exs_path)
  end

  defp folder_name(project) do
    project
    |> root_path()
    |> Path.basename()
  end

  def elixir_project?(%__MODULE__{} = project) do
    ex_files = project |> root_path() |> Path.join("*.ex") |> Path.wildcard()
    exs_files = project |> root_path() |> Path.join("*.exs") |> Path.wildcard()

    ex_files != [] or exs_files != []
  end

  @doc """
  Finds the closest project that contains the given URI.
  """
  def project_for_uri(projects, uri) do
    path = Document.Path.from_uri(uri)
    closest_project_for_path(projects, path)
  end

  @doc """
  Finds the closest project that contains the given document.
  """
  def project_for_document(projects, %Document{} = document) do
    closest_project_for_path(projects, document.path)
  end

  # Finds the most specific project containing the path (longest root path wins).
  defp closest_project_for_path(projects, path) do
    projects
    |> Enum.filter(fn project ->
      Forge.Path.parent_path?(path, root_path(project))
    end)
    |> Enum.max_by(fn project -> byte_size(root_path(project)) end, fn -> nil end)
  end

  @doc """
  Checks if the given path is within the project directory.

  If the path is within a subdirectory of the project and a
  mix file exists, it returns false.
  """
  def within_project?(%__MODULE__{} = project, path) do
    root_path = if project.mix_project?, do: find_parent_root_dir(path), else: root_path(project)
    project_path = root_path(project)

    Forge.Path.parent_path?(root_path, project_path)
  end

  @doc """
  Finds or creates the project for the given path.
  """
  def find_project(path) do
    project_root = find_parent_root_dir(path)

    if !is_nil(project_root) do
      new(project_root)
    end
  end

  @doc """
  Returns the `apps_path` configured in `mix.exs` when `project_path` is an
  umbrella root, otherwise returns `nil`.
  """
  def umbrella_apps_path(project_path) when is_binary(project_path) do
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

  def find_parent_root_dir(path) do
    path = Forge.Document.Path.from_uri(path)
    path = path |> Path.expand() |> path_or_parent_dir()
    boundary = workspace_boundary_path()

    segments = Path.split(path)

    case traverse_path(segments, boundary) do
      nil -> nil
      root -> Document.Path.to_uri(root)
    end
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
        {_, rest} = List.pop_at(segments, -1)
        traverse_path(rest, boundary)
    end
  end

  def ensure_hex_and_rebar do
    if Internet.connected_to_internet?() do
      Mix.Task.run("local.hex", ~w(--force --if-missing))
      Mix.Task.run("local.rebar", ~w(--force --if-missing))
      :ok
    else
      Logger.warning("Could not connect to hex.pm, dependencies will not be fetched")
      :ok
    end
  end

  defp workspace_boundary_path do
    case Forge.Workspace.get_workspace() do
      %Forge.Workspace{root_path: root_path} when is_binary(root_path) ->
        Path.expand(root_path)

      _ ->
        nil
    end
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
    do_find_umbrella_root(Path.dirname(project_path), project_path, boundary)
  end

  defp do_find_umbrella_root(current_path, project_path, boundary) do
    if !boundary_reached?(current_path, boundary) do
      case umbrella_apps_path(current_path) do
        apps_path when is_binary(apps_path) ->
          apps_root = Path.expand(Path.join(current_path, apps_path))

          if project_path == apps_root or Forge.Path.parent_path?(project_path, apps_root) do
            current_path
          else
            next_parent(current_path, project_path, boundary)
          end

        _ ->
          next_parent(current_path, project_path, boundary)
      end
    end
  end

  defp next_parent(current_path, project_path, boundary) do
    parent = Path.dirname(current_path)

    cond do
      parent == current_path ->
        nil

      boundary_reached?(parent, boundary) ->
        nil

      true ->
        do_find_umbrella_root(parent, project_path, boundary)
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
end
