defmodule Engine.Deps do
  @moduledoc """
  Reads the project's dependency and hex configuration from within the
  engine BEAM, where the project's own Mix context (and thus the `Hex`
  archive) is loaded. Expert calls these via `EngineApi.call/4` so the
  LSP always sees the repo config from the project's own environment —
  honoring `HEX_HOME`, per-project auth keys, and oauth tokens.

  Every function that needs `Mix.Project.*` state (everything except
  `dep_version/1`, which reads from the global `Application` registry)
  runs inside `Engine.Mix.in_project/1` so `Mix.ProjectStack` is
  populated for the duration of the call. The engine's other RPC
  handler processes don't automatically push the project onto the
  stack — only the compile/index paths do — so bare `Mix.Project.*`
  calls from an RPC handler return `nil`/empty for the project-file
  lookups we need here.

  Every function is designed to degrade to `:error` / `nil` / `[]`
  when the mix/hex archive isn't loaded (e.g., the project doesn't declare
  any hex deps) or the engine isn't running as a project node.
  """

  @doc """
  Returns the resolved repo config for `name` — for example `"hexpm"`,
  `"hexpm:myorg"`, or a self-hosted repo name like `"oban"`.

  Delegates to `Hex.Repo.get_repo/1`, which is the canonical entry
  point hex itself uses when fetching packages from that repo. The
  returned map includes `:url`, `:auth_key`, `:public_key`,
  `:oauth_token` (for hex.pm), and any other fields hex has learned to
  track for the repo.
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
      # Raw binaries/nils fall through `Engine.Mix.in_project/1`'s
      # catch-all clause and get wrapped as `{:ok, binary_or_nil}`.
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

  Paths are returned absolute. For non-umbrella projects, this is a
  single-element list containing the root project file. For umbrellas,
  it includes the umbrella root and each child's project file.
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
  in its "Current" column, pulled directly from the running BEAM's
  application specs rather than re-parsing `mix.lock`.

  `app` may be a binary (`"bandit"`) or an atom (`:bandit`). Binaries
  are resolved via `String.to_existing_atom/1` so that Expert passing
  a package name the project has never loaded yields `:error` instead
  of leaking a new atom.

  Returns `:error` when the application isn't loaded (e.g. a dev-only
  dep without `Mix.env() == :dev`, or a brand-new dep that hasn't been
  `mix deps.get`'d yet).

  Unlike the other functions in this module, `dep_version/1` does not
  need `Mix.Project` state — `Application.spec/2` reads from the
  global OTP application controller, which is populated when the
  project's deps are loaded at engine startup.
  """
  @spec dep_version(atom() | String.t()) :: {:ok, String.t()} | :error
  def dep_version(app) when is_binary(app) do
    dep_version(String.to_existing_atom(app))
  rescue
    ArgumentError -> :error
  end

  def dep_version(app) when is_atom(app) do
    case Application.spec(app, :vsn) do
      nil -> :error
      vsn -> {:ok, to_string(vsn)}
    end
  end

  @doc """
  Returns the user's hex config as a keyword list (the `Hex.Config.read/0`
  result). Primarily useful for diagnostics; resolved repo configs come
  from `get_repo/1` which handles merging/auth internally.
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
  hex config — for example `["oban"]` for a user with a self-hosted
  Oban repo. Excludes the default `""` entry, `"hexpm"`, and hex.pm
  organization repos (`"hexpm:<org>"`).

  Used by Expert to proactively fetch package lists from custom repos
  so that package completion works without needing the `repo:` option.
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

  Uses `Hex.SCM.cache_path/3` to locate the tarball in the user's
  hex cache (typically `~/.hex/packages/<repo>/<package>-<version>.tar`).

  Returns `{:ok, path}` when the file is present, `:error` otherwise.
  The caller (Expert) can then use `:hex_tarball.unpack({:file, path}, :none)`
  from its own `hex_core` dependency to extract metadata without
  decompressing the source contents.
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
