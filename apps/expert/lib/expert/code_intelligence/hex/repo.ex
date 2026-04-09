defmodule Expert.CodeIntelligence.Hex.Repo do
  @moduledoc """
  Resolves a hex repo name (default `"hexpm"`, a hex.pm organization
  `"hexpm:<org>"`, or a self-hosted repo) into a `:hex_core` config map.

  All repo lookups are delegated to `Engine.Deps.get_repo/1` via an
  RPC to the project's engine node — the engine runs under the project's
  own Mix/`Hex` archive, so the resolution uses hex's canonical logic
  (auth key refresh, oauth tokens, key rotation) and stays in sync as
  hex evolves. Expert itself never parses `hex.config`.

  Returns `:error` for any repo that cannot be resolved so callers
  never act on incorrect data.
  """

  alias Expert.EngineApi
  alias Forge.Project

  @type config :: map()

  @spec default() :: :hex_core.config()
  def default, do: :hex_core.default_config()

  @spec resolve(String.t(), keyword()) :: {:ok, config()} | :error
  def resolve(name, opts \\ []) when is_binary(name) do
    do_resolve(name, Keyword.get(opts, :project))
  end

  # Plain hex.pm: the `:hex_core` default config already has the right
  # `repo_url`, `api_url`, and `repo_public_key` — no engine round-trip
  # needed. Public package search and version lookup work without auth.
  defp do_resolve("hexpm", _project), do: {:ok, default()}

  # Organization scopes go through the hex.pm API endpoint using the
  # stored auth key. We always need an engine round-trip here to fetch
  # the org's auth key from the user's hex config.
  defp do_resolve("hexpm:" <> org, %Project{} = project) do
    with {:ok, entry} <- engine_get_repo(project, "hexpm:" <> org),
         {:ok, key} <- fetch_string(entry, :auth_key) do
      {:ok, Map.merge(default(), %{api_organization: org, api_key: key})}
    else
      _ -> :error
    end
  end

  # Self-hosted repos use the repo protocol (`:hex_repo.get_package`)
  # instead of the API endpoint — the URL in hex.config points at the
  # signed registry tarball, not a hex.pm-compatible API. We thread
  # `repo_url`/`repo_key`/`repo_public_key` into the `:hex_core` config
  # so `:hex_repo` can fetch + verify the registry.
  defp do_resolve(name, %Project{} = project) do
    with {:ok, entry} <- engine_get_repo(project, name),
         {:ok, url} <- fetch_string(entry, :url) do
      {:ok, build_repo_config(name, url, entry)}
    else
      _ -> :error
    end
  end

  # Without a project we can't RPC into an engine, so any non-default
  # repo is unresolvable. This is a stricter invariant than the old
  # file-parsing fallback, but it matches how hex itself expects to
  # resolve repos: from inside the project's Mix context.
  defp do_resolve(_name, nil), do: :error

  defp build_repo_config(name, url, entry) do
    auth_key =
      case fetch_string(entry, :auth_key) do
        {:ok, key} -> key
        :error -> nil
      end

    base = %{
      repo_name: name,
      repo_url: url,
      repo_key: auth_key,
      repo_verify: true
    }

    overrides =
      case Map.get(entry, :public_key) do
        key when is_binary(key) -> Map.put(base, :repo_public_key, key)
        _ -> base
      end

    Map.merge(default(), overrides)
  end

  defp engine_get_repo(%Project{} = project, name) do
    case EngineApi.call(project, Engine.Deps, :get_repo, [name]) do
      {:ok, %{} = entry} -> {:ok, entry}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end
end
