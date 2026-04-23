defmodule Expert.CodeIntelligence.Hex do
  @moduledoc """
  Orchestrates hex-aware completion and hover for `mix.exs` documents.

  Uses `Hex.Context` to detect whether the cursor is inside `deps/0` and which
  repo (default `"hexpm"`, an organization, or a self-hosted repo) the dep
  references. Routes through `Hex.Cache` (DETS, stale-on-error) to `Hex.Api`,
  which delegates to `:hex_api_package` from `:hex_core`.
  """

  alias Expert.CodeIntelligence.Hex.Api
  alias Expert.CodeIntelligence.Hex.Cache
  alias Expert.CodeIntelligence.Hex.Candidate
  alias Expert.CodeIntelligence.Hex.Context
  alias Expert.CodeIntelligence.Hex.Repo
  alias Expert.EngineApi
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Project

  # 1 hour TTL on hex.pm responses.
  @ttl_ms 60 * 60 * 1_000

  @opts [
    %{name: "app", description: "Whether to read the app file"},
    %{name: "env", description: "MIX_ENV used when fetching the dep"},
    %{name: "compile", description: "Custom compile command"},
    %{name: "optional", description: "Mark the dep as optional"},
    %{name: "only", description: "Environments in which the dep is loaded"},
    %{name: "targets", description: "Mix targets in which the dep is loaded"},
    %{name: "override", description: "Override transitive deps"},
    %{name: "manager", description: "Build manager (mix, rebar, rebar3, make)"},
    %{name: "runtime", description: "Whether to start the application at runtime"},
    %{name: "system_env", description: "Env vars for fetch and compile"},
    %{name: "git", description: "Git URL"},
    %{name: "github", description: "GitHub user/repo shorthand"},
    %{name: "ref", description: "Git ref/sha"},
    %{name: "branch", description: "Git branch"},
    %{name: "tag", description: "Git tag"},
    %{name: "submodules", description: "Whether to clone submodules"},
    %{name: "sparse", description: "Sparse-checkout pattern"},
    %{name: "subdir", description: "Subdirectory inside the repository"},
    %{
      name: "depth",
      description:
        "Creates a shallow clone of the Git repository, limiting the history to the specified number of commits. This can significantly improve clone speed for large repositories when full history is not needed. The value must be a positive integer, typically 1. When using :depth with :ref, a fully spelled hex object name (a 40-character SHA-1 hash) is required."
    },
    %{name: "path", description: "Local path to the dep source"},
    %{
      name: "in_umbrella",
      description:
        ~S|When true, sets a path dependency pointing to "../#{app}", sharing the same environment as the current application|
    },
    %{
      name: "hex",
      description: "The name of the package, which defaults to the application name"
    },
    %{name: "repo", description: "Hex repo name"},
    %{
      name: "warn_if_outdated",
      description: "Warn if there is a more recent version of the package published on Hex.pm"
    }
  ]

  @doc """
  Returns `true` if `document` is a Mix project file (`mix.exs` by
  convention, but anything returned by `Mix.Project.project_file/0`)
  for `project` — including any umbrella child project files.
  """
  @spec project_file?(Project.t() | nil, Document.t() | String.t() | nil) :: boolean()
  def project_file?(project, document_or_path)
  def project_file?(nil, _), do: false
  def project_file?(_, nil), do: false
  def project_file?(_, %Document{path: nil}), do: false

  def project_file?(%Project{} = project, %Document{path: path}) do
    project_file?(project, path)
  end

  def project_file?(%Project{} = project, path) when is_binary(path) do
    MapSet.member?(project_files(project), normalize_path(path))
  end

  defp project_files(%Project{} = project) do
    key = {__MODULE__, :project_files, project.root_uri}

    case :persistent_term.get(key, :__miss__) do
      :__miss__ ->
        files = fetch_project_files(project)
        if not Enum.empty?(files), do: :persistent_term.put(key, files)
        files

      files ->
        files
    end
  end

  defp fetch_project_files(%Project{} = project) do
    case EngineApi.call(project, Engine.Deps, :project_files, []) do
      list when is_list(list) ->
        list |> MapSet.new(&normalize_path/1)

      _ ->
        MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  catch
    _, _ -> MapSet.new()
  end

  defp normalize_path(path) when is_binary(path) do
    path |> Path.expand() |> Forge.Path.normalize()
  end

  @spec installed_version(Project.t() | nil, String.t()) :: String.t() | nil
  def installed_version(nil, _package), do: nil

  def installed_version(%Project{} = project, package) when is_binary(package) do
    case EngineApi.call(project, Engine.Deps, :dep_version, [package]) do
      {:ok, version} when is_binary(version) -> version
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @spec candidates(Analysis.t(), Position.t(), Project.t() | nil) :: [struct()]
  def candidates(%Analysis{} = analysis, %Position{} = position, project \\ nil) do
    case Context.detect(analysis, position) do
      {:ok, ctx} -> candidates_for_context(ctx, project)
      :error -> []
    end
  end

  @spec candidates_for_context(Context.t(), Project.t() | nil) :: [struct()]
  def candidates_for_context(ctx, project \\ nil)

  def candidates_for_context(%{slot: :name, prefix: prefix, repo: repo}, project),
    do: package_candidates(project, repo, prefix)

  def candidates_for_context(
        %{slot: :version, package: package, repo: repo, prefix: prefix},
        project
      )
      when is_binary(package),
      do: version_candidates(project, repo, package, prefix)

  def candidates_for_context(%{slot: :opts, prefix: prefix}, _project),
    do: opt_candidates(prefix)

  def candidates_for_context(_ctx, _project), do: []

  @spec fetch_package(String.t(), String.t(), Project.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def fetch_package(repo, package_name, project \\ nil)
      when is_binary(repo) and is_binary(package_name) do
    repo = resolve_package_repo(project, repo, package_name)

    case Repo.resolve(repo, project: project) do
      {:ok, config} ->
        Cache.get_or_fetch(
          Cache,
          {:package, project_scope(project), repo, package_name},
          @ttl_ms,
          fn -> Api.fetch_package(config, project, package_name) end
        )

      :error ->
        {:error, :unknown_repo}
    end
  end

  @spec fetch_releases(String.t(), String.t(), Project.t() | nil) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_releases(repo, package_name, project \\ nil)
      when is_binary(repo) and is_binary(package_name) do
    repo = resolve_package_repo(project, repo, package_name)

    case Repo.resolve(repo, project: project) do
      {:ok, config} ->
        Cache.get_or_fetch(
          Cache,
          {:releases, project_scope(project), repo, package_name},
          @ttl_ms,
          fn -> Api.fetch_releases(config, package_name) end
        )

      :error ->
        {:error, :unknown_repo}
    end
  end

  defp project_scope(nil), do: :__local__
  defp project_scope(%Project{} = project), do: project.root_uri

  defp package_candidates(_project, _repo, ""), do: []
  defp package_candidates(_project, _repo, prefix) when byte_size(prefix) < 2, do: []

  defp package_candidates(project, repo, prefix) do
    search_repo_candidates(project, repo, prefix) ++
      custom_repo_candidates(project, prefix)
  end

  defp search_repo_candidates(project, repo, prefix) do
    with {:ok, config} <- Repo.resolve(repo, project: project),
         {:ok, packages} when is_list(packages) <-
           Cache.get_or_fetch(
             Cache,
             {:search, project_scope(project), repo, prefix},
             @ttl_ms,
             fn -> Api.search_packages(config, prefix) end
           ) do
      Enum.map(packages, &package_candidate(&1, project, repo))
    else
      _ -> []
    end
  end

  defp custom_repo_candidates(nil, _prefix), do: []

  defp custom_repo_candidates(%Project{} = project, prefix) do
    for repo <- configured_repos(project),
        name <- repo_package_names(project, repo),
        String.starts_with?(name, prefix) do
      %Candidate.Package{name: name, repo: repo}
    end
  end

  defp configured_repos(%Project{} = project) do
    Cache
    |> Cache.get_or_fetch(
      {:configured_repos, project_scope(project)},
      @ttl_ms,
      fn ->
        case EngineApi.call(project, Engine.Deps, :configured_repos, []) do
          repos when is_list(repos) -> {:ok, repos}
          _ -> {:ok, []}
        end
      end
    )
    |> case do
      {:ok, repos} -> repos
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp repo_package_names(%Project{} = project, repo) do
    Cache
    |> Cache.get_or_fetch(
      {:repo_names, project_scope(project), repo},
      @ttl_ms,
      fn ->
        with {:ok, config} <- Repo.resolve(repo, project: project) do
          Api.fetch_repo_names(config)
        end
      end
    )
    |> case do
      {:ok, names} -> names
      _ -> []
    end
  end

  # When the detected repo is "hexpm" (the default, no `repo:` option yet),
  # check if the package lives in a custom repo. This lets version completion
  # work for `{:oban_pro, "~> ` before the user adds `repo: "oban"`.
  defp resolve_package_repo(%Project{} = project, "hexpm", package) do
    Enum.find_value(configured_repos(project), "hexpm", fn repo ->
      names = repo_package_names(project, repo)
      if Enum.member?(names, package), do: repo
    end)
  end

  defp resolve_package_repo(_project, repo, _package), do: repo

  defp package_candidate(%{"name" => name} = pkg, project, repo) do
    meta = Map.get(pkg, "meta") || %{}
    downloads = Map.get(pkg, "downloads") || %{}

    %Candidate.Package{
      name: name,
      description: Map.get(meta, "description"),
      latest_version: Map.get(pkg, "latest_stable_version") || Map.get(pkg, "latest_version"),
      downloads: Map.get(downloads, "all"),
      installed_version: installed_version(project, name),
      repo: repo
    }
  end

  defp version_candidates(project, repo, package, prefix) do
    repo = resolve_package_repo(project, repo, package)

    case fetch_releases(repo, package, project) do
      {:ok, releases} when is_list(releases) ->
        releases
        |> Enum.reject(fn release -> is_nil(Map.get(release, "version")) end)
        |> build_version_candidates(package, prefix)

      _ ->
        []
    end
  end

  @max_versions 50

  defp build_version_candidates(releases, package, prefix) do
    # compound statements are more difficult to provide completions
    if is_binary(prefix) and Regex.match?(~r/\b(?:or|and)\b/, prefix) do
      []
    else
      do_build_version_candidates(releases, package, prefix)
    end
  end

  defp do_build_version_candidates(releases, package, prefix) do
    filtered =
      case version_prefix_filter(prefix) do
        "" -> releases
        filter -> Enum.filter(releases, &String.starts_with?(&1["version"] || "", filter))
      end

    parsed =
      Enum.map(filtered, fn release ->
        raw = Map.get(release, "version")

        parsed_version =
          case Version.parse(raw) do
            {:ok, %Version{} = v} -> v
            :error -> nil
          end

        {release, parsed_version}
      end)

    {parseable, unparseable} = Enum.split_with(parsed, fn {_release, v} -> v != nil end)

    top_parseable =
      parseable
      |> Enum.sort_by(fn {_release, v} -> v end, {:desc, Version})
      |> Enum.take(@max_versions)
      |> Enum.map(fn {release, _v} -> release end)

    trailing = Enum.map(unparseable, fn {release, _v} -> release end)

    (top_parseable ++ trailing)
    |> Enum.with_index()
    |> Enum.map(fn {release, idx} ->
      %Candidate.Version{
        package: package,
        version: Map.get(release, "version"),
        index: idx,
        prefix: prefix,
        retirement: normalize_retirement(Map.get(release, "retirement"))
      }
    end)
  end

  defp version_prefix_filter(nil), do: ""

  defp version_prefix_filter(prefix) when is_binary(prefix) do
    case Regex.run(~r/[\w.+\-]*$/, prefix) do
      [match] -> match
      _ -> ""
    end
  end

  defp normalize_retirement(nil), do: nil

  defp normalize_retirement(%{"reason" => reason} = retirement) do
    %{reason: reason, message: Map.get(retirement, "message")}
  end

  defp normalize_retirement(_), do: nil

  defp opt_candidates(prefix) do
    @opts
    |> Enum.filter(&String.starts_with?(&1.name, prefix))
    |> Enum.map(&%Candidate.Opt{name: &1.name, description: &1.description})
  end
end
