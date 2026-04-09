defmodule Expert.CodeIntelligence.Hex.Hover do
  @moduledoc """
  Renders a hover tooltip for a hex package referenced in `mix.exs` deps.
  """

  alias Expert.CodeIntelligence.Hex
  alias Expert.CodeIntelligence.Hex.Context
  alias Forge.Ast.Analysis
  alias Forge.Document.Position
  alias Forge.Project

  @doc """
  Returns markdown for a hex package hover, or `:error` if the cursor is not
  on a deps package atom (or the package metadata cannot be loaded).
  """
  @spec content(Analysis.t(), Position.t(), Project.t() | nil) :: {:ok, String.t()} | :error
  def content(%Analysis{} = analysis, %Position{} = position, project \\ nil) do
    with {:ok, %{slot: :name, package: package, repo: repo}} when is_binary(package) <-
           Context.detect(analysis, position),
         {:ok, data} <- Hex.fetch_package(repo, package, project) do
      {:ok, render(data, Hex.installed_version(project, package))}
    else
      _ -> :error
    end
  end

  defp render(%{"name" => name} = data, installed) do
    meta = Map.get(data, "meta") || %{}
    downloads = Map.get(data, "downloads") || %{}

    sections =
      [
        "## #{name}",
        Map.get(meta, "description"),
        version_line(data, installed),
        license_line(meta),
        downloads_line(downloads),
        links_section(meta, data)
      ]
      |> Enum.reject(&blank?/1)

    Enum.join(sections, "\n\n")
  end

  defp version_line(data, installed) do
    latest = data["latest_stable_version"] || data["latest_version"]

    case {installed, latest} do
      {installed, latest} when is_binary(installed) and is_binary(latest) ->
        case compare_versions(installed, latest) do
          :lt -> "**Installed:** `#{installed}` _(update available: `#{latest}`)_"
          _ -> "**Installed:** `#{installed}` _(up to date)_"
        end

      {installed, _} when is_binary(installed) ->
        "**Installed:** `#{installed}`"

      {_, latest} when is_binary(latest) ->
        "**Latest:** `#{latest}`"

      _ ->
        nil
    end
  end

  defp compare_versions(a, b) do
    with {:ok, va} <- Version.parse(a),
         {:ok, vb} <- Version.parse(b) do
      Version.compare(va, vb)
    else
      _ -> :eq
    end
  end

  defp license_line(%{"licenses" => licenses} = _meta) when is_list(licenses) do
    "**License:** #{Enum.join(licenses, ", ")}"
  end

  defp license_line(_), do: nil

  defp downloads_line(%{"all" => count}) when is_integer(count) do
    "**Downloads:** #{format_count(count)}"
  end

  defp downloads_line(_), do: nil

  defp links_section(meta, data) do
    hexdocs = Map.get(data, "docs_html_url")
    hexpm = Map.get(data, "html_url")
    extra = Map.get(meta, "links") || %{}

    pieces =
      [
        hexdocs && "[hexdocs](#{hexdocs})",
        hexpm && "[hex.pm](#{hexpm})"
      ]
      |> Enum.concat(Enum.map(extra, fn {label, url} -> "[#{label}](#{url})" end))
      |> Enum.reject(&is_nil/1)

    case pieces do
      [] -> nil
      list -> Enum.join(list, "\n\n")
    end
  end

  defp format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n), do: Integer.to_string(n)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
