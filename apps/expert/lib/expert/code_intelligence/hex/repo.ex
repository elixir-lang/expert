defmodule Expert.CodeIntelligence.Hex.Repo do
  @moduledoc """
  Resolves a hex repo name (default `"hexpm"`, a hex.pm organization
  `"hexpm:<org>"`, or a self-hosted repo) into a `:hex_core` config map.
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

  defp do_resolve("hexpm", _project), do: {:ok, default()}

  defp do_resolve("hexpm:" <> org, %Project{} = project) do
    with {:ok, entry} <- engine_get_repo(project, "hexpm:" <> org),
         {:ok, key} <- fetch_string(entry, :auth_key) do
      {:ok, Map.merge(default(), %{api_organization: org, api_key: key})}
    else
      _ -> :error
    end
  end

  defp do_resolve(name, %Project{} = project) do
    with {:ok, entry} <- engine_get_repo(project, name),
         {:ok, url} <- fetch_string(entry, :url) do
      {:ok, build_repo_config(name, url, entry)}
    else
      _ -> :error
    end
  end

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
