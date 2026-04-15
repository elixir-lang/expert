defmodule Expert.CodeIntelligence.Hex.Api do
  @moduledoc """
  Thin Elixir wrapper around `:hex_api_package` from `:hex_core`.

  All functions take a hex_core config map (built by `Expert.CodeIntelligence.Hex.Repo`)
  so the same code path serves the public hex.pm registry, hex.pm
  organizations, and self-hosted hex repos.
  """

  alias Expert.EngineApi
  alias Forge.Project

  @search_params [{"sort", "downloads"}, {"per_page", "50"}]

  @spec search_packages(:hex_core.config(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def search_packages(_config, query) when not is_binary(query) or query == "" do
    {:ok, []}
  end

  def search_packages(config, query) when is_binary(query) do
    query_binary = "name:#{query}*"

    case :hex_api_package.search(config, query_binary, @search_params) do
      {:ok, {status, _headers, body}} when status in 200..299 and is_list(body) ->
        {:ok, body}

      {:ok, {status, _, _}} ->
        {:error, {:http_status, status}}

      {:error, _} = error ->
        error
    end
  end

  @spec fetch_package(:hex_core.config(), Project.t() | nil, String.t()) ::
          {:ok, map()} | {:error, term()}
  def fetch_package(_config, _project, ""), do: {:error, :empty_name}

  def fetch_package(%{repo_name: "hexpm"} = config, _project, name) when is_binary(name) do
    case :hex_api_package.get(config, name) do
      {:ok, {status, _headers, body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, {status, _, _}} ->
        {:error, {:http_status, status}}

      {:error, _} = error ->
        error
    end
  end

  def fetch_package(%{repo_name: repo} = config, project, name) when is_binary(name) do
    case :hex_repo.get_package(config, name) do
      {:ok, {status, _headers, data}} when status in 200..299 ->
        {:ok,
         data
         |> normalize_repo_package(name)
         |> enrich_from_tarball(repo, name, project)}

      {:ok, {status, _, _}} ->
        {:error, {:http_status, status}}

      {:error, _} = error ->
        error
    end
  end

  defp enrich_from_tarball(data, repo, name, %Project{} = project) do
    data
    |> sorted_versions()
    |> Enum.find_value(data, fn version ->
      with {:ok, path} <- cached_tarball_path(project, repo, name, version),
           {:ok, meta} <- tarball_metadata(path),
           enriched = merge_tarball_metadata(data, meta),
           true <- Map.has_key?(enriched, "meta") do
        enriched
      else
        _ -> nil
      end
    end)
  end

  defp enrich_from_tarball(data, _repo, _name, _project), do: data

  defp sorted_versions(%{"releases" => releases}) when is_list(releases) do
    releases
    |> Enum.map(& &1["version"])
    |> Enum.filter(&is_binary/1)
    |> Enum.sort_by(
      fn v ->
        case Version.parse(v) do
          {:ok, parsed} -> parsed
          :error -> Version.parse!("0.0.0")
        end
      end,
      {:desc, Version}
    )
  end

  defp sorted_versions(_), do: []

  defp cached_tarball_path(%Project{} = project, repo, package, version) do
    case EngineApi.call(project, Engine.Deps, :cached_tarball_path, [repo, package, version]) do
      {:ok, path} when is_binary(path) -> {:ok, path}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp merge_tarball_metadata(data, metadata) do
    meta =
      %{}
      |> put_if_present("description", metadata["description"])
      |> put_if_present("licenses", metadata["licenses"])
      |> put_if_present("links", metadata["links"])

    if map_size(meta) > 0 do
      Map.put(data, "meta", Map.merge(Map.get(data, "meta") || %{}, meta))
    else
      data
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, _key, []), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp normalize_repo_package(data, name) do
    %{
      "name" => name,
      "releases" =>
        data
        |> Map.get(:releases, [])
        |> Enum.map(fn release ->
          version = release |> Map.get(:version) |> to_string()
          %{"version" => version}
        end)
    }
  end

  @doc """
  Returns the list of package names available in a repo.
  """
  @spec fetch_repo_names(:hex_core.config()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_repo_names(config) do
    case :hex_repo.get_names(config) do
      {:ok, {status, _headers, %{packages: packages}}} when status in 200..299 ->
        {:ok, Enum.map(packages, fn p -> to_string(p.name) end)}

      {:ok, {status, _, _}} ->
        {:error, {:http_status, status}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Uses `:hex_tarball.unpack({:file, path}, :none)` to read only the
  `metadata.config` entry — source contents are never decompressed.
  """
  @spec tarball_metadata(String.t()) :: {:ok, map()} | {:error, term()}
  def tarball_metadata(path) when is_binary(path) do
    case :hex_tarball.unpack({:file, String.to_charlist(path)}, :none) do
      {:ok, %{metadata: metadata}} when is_map(metadata) -> {:ok, metadata}
      {:error, _} = error -> error
    end
  end

  @doc """
  Returns the list of releases for `name` with retirement metadata,
  using the repo protocol (`:hex_repo.get_package/2`) regardless of
  whether `config` is a hexpm or self-hosted repo config.
  """
  @spec fetch_releases(:hex_core.config(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_releases(_config, ""), do: {:error, :empty_name}

  def fetch_releases(config, name) when is_binary(name) do
    case :hex_repo.get_package(config, name) do
      {:ok, {status, _headers, data}} when status in 200..299 and is_map(data) ->
        {:ok, normalize_release_list(data)}

      {:ok, {status, _, _}} ->
        {:error, {:http_status, status}}

      {:error, _} = error ->
        error
    end
  end

  defp normalize_release_list(data) do
    data
    |> Map.get(:releases, [])
    |> Enum.map(fn release ->
      %{
        "version" => release |> Map.get(:version) |> to_string(),
        "retirement" => normalize_retirement(Map.get(release, :retired))
      }
    end)
  end

  defp normalize_retirement(nil), do: nil

  defp normalize_retirement(%{reason: reason} = retired) do
    %{
      "reason" => retirement_reason(reason),
      "message" => retired |> Map.get(:message, "") |> to_string()
    }
  end

  defp normalize_retirement(_), do: nil

  defp retirement_reason(reason) when is_atom(reason) do
    reason
    |> Atom.to_string()
    |> String.trim_leading("RETIRED_")
    |> String.downcase()
  end

  defp retirement_reason(reason) when is_binary(reason), do: reason
  defp retirement_reason(_), do: "retired"
end
