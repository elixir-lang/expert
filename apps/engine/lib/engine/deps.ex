defmodule Engine.Deps do
  @moduledoc """
  Reads the project's dependency and hex configuration from within the
  project, honoring `HEX_HOME`, per-project auth keys, and oauth tokens.
  """

  @doc """
  Returns the resolved repo config for `name` — for example `"hexpm"`,
  `"hexpm:myorg"`, or a self-hosted repo name like `"oban"`.
  """
  @spec get_repo(String.t()) :: {:ok, map()} | :error
  def get_repo(name) when is_binary(name) do
    case Engine.Mix.in_project(fn _module ->
           case safe_call(Hex.Repo, :get_repo, [name]) do
             %{} = repo -> {:ok, repo}
             _ -> :error
           end
         end) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  @doc """
  Returns the canonical path to the Mix project file for the project
  the engine is running under — usually `mix.exs`, but nothing in Mix
  requires that name. Inside an umbrella app, returns the umbrella's
  project file when `:umbrella` is passed.
  """
  @spec project_file(:app | :umbrella) :: String.t() | nil
  def project_file(scope \\ :app)

  def project_file(:app) do
    case Engine.Mix.in_project(fn _module -> safe_call(Mix.Project, :project_file, []) end) do
      {:ok, path} when is_binary(path) -> path
      _ -> nil
    end
  end

  def project_file(:umbrella) do
    result =
      Engine.Mix.in_project(fn _module ->
        case safe_call(Mix.Project, :parent_umbrella_project_file, []) do
          nil -> safe_call(Mix.Project, :project_file, [])
          path -> path
        end
      end)

    case result do
      {:ok, path} when is_binary(path) -> path
      _ -> nil
    end
  end

  @doc """
  Returns the list of all Mix project files the engine's project tree
  contains — the root project file plus every umbrella child's project
  file. Used by Expert to gate hex-specific code lens/hover/completion
  to only documents that are actually Mix project config files.
  """
  @spec project_files() :: [String.t()]
  def project_files do
    result =
      Engine.Mix.in_project(fn _module ->
        Mix.Project
        |> safe_call(:project_file, [])
        |> List.wrap()
        |> Enum.concat(umbrella_child_project_files())
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Path.expand/1)
        |> Enum.uniq()
      end)

    case result do
      {:ok, files} when is_list(files) -> files
      _ -> []
    end
  end

  defp umbrella_child_project_files do
    case safe_call(Mix.Project, :apps_paths, []) do
      %{} = paths -> Enum.map(paths, fn {_app, app_path} -> Path.join(app_path, "mix.exs") end)
      _ -> []
    end
  end

  @doc """
  Returns the currently installed version of `app` from the project's
  loaded applications — equivalent to what `mix hex.outdated` reports
  in its "Current" column.
  """
  @spec dep_version(atom()) :: {:ok, String.t()} | :error
  def dep_version(app) when is_atom(app) do
    result =
      Engine.Mix.in_project(fn _module ->
        with %{} = lock <- safe_call(Mix.Dep.Lock, :read, []) do
          lock |> Map.get(app, []) |> Enum.at(2)
        else
          _ -> nil
        end
      end)

    case result do
      {:ok, version} when is_binary(version) ->
        {:ok, version}

      _ ->
        case Application.spec(app, :vsn) do
          nil -> :error
          vsn -> {:ok, to_string(vsn)}
        end
    end
  end

  @doc """
  Returns the user's hex config
  """
  @spec read_config() :: {:ok, keyword()} | :error
  def read_config do
    case Engine.Mix.in_project(fn _module ->
           case safe_call(Hex.Config, :read, []) do
             config when is_list(config) -> {:ok, config}
             _ -> :error
           end
         end) do
      {:ok, config} when is_list(config) -> {:ok, config}
      _ -> :error
    end
  end

  @doc """
  Returns the names of non-hexpm custom repos configured in the user's
  hex config — for example `["oban"]`.
  """
  @spec configured_repos() :: [String.t()]
  def configured_repos do
    case read_config() do
      {:ok, config} ->
        config
        |> Keyword.get(:"$repos", %{})
        |> Map.keys()
        |> Enum.filter(&custom_repo?/1)

      :error ->
        []
    end
  end

  defp custom_repo?(""), do: false
  defp custom_repo?("hexpm"), do: false
  defp custom_repo?("hexpm:" <> _), do: false
  defp custom_repo?(name) when is_binary(name), do: true
  defp custom_repo?(_), do: false

  @doc """
  Returns the local filesystem path to a cached hex tarball for the
  given `repo`, `package`, and `version`, if it exists on disk.
  """
  @spec cached_tarball_path(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :error
  def cached_tarball_path(repo, package, version)
      when is_binary(repo) and is_binary(package) and is_binary(version) do
    with path when is_binary(path) <- safe_call(Hex.SCM, :cache_path, [repo, package, version]),
         true <- File.exists?(path) do
      {:ok, path}
    else
      _ -> :error
    end
  end

  def cached_tarball_path(_repo, _package, _version), do: :error

  defp safe_call(module, fun, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, fun, length(args)) do
      apply(module, fun, args)
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
