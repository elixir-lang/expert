defmodule Expert.CodeIntelligence.Hex.ApiTest do
  use ExUnit.Case, async: false
  use Patch

  alias Expert.CodeIntelligence.Hex.Api
  alias Expert.CodeIntelligence.Hex.Repo

  describe "search_packages/2" do
    test "returns an empty list for a blank query without making a request" do
      patch(:hex_api_package, :search, fn _, _, _ -> flunk("should not call hex_api_package") end)
      assert {:ok, []} = Api.search_packages(Repo.default(), "")
    end

    test "delegates to :hex_api_package.search with the right query and sort params" do
      patch(:hex_api_package, :search, fn _config, _query, _params ->
        {:ok, {200, %{}, [%{"name" => "phoenix"}]}}
      end)

      assert {:ok, [%{"name" => "phoenix"}]} = Api.search_packages(Repo.default(), "phoe")

      assert_called(:hex_api_package.search(_config, "name:phoe*", _params))
    end

    test "passes the caller's config through unchanged so api_organization is honored" do
      patch(:hex_api_package, :search, fn config, _query, _params ->
        send(self(), {:saw_config, config})
        {:ok, {200, %{}, []}}
      end)

      org_config = Map.merge(Repo.default(), %{api_organization: "myorg", api_key: "tok"})
      Api.search_packages(org_config, "phoe")

      assert_received {:saw_config, %{api_organization: "myorg", api_key: "tok"}}
    end

    test "translates non-2xx statuses to {:error, {:http_status, code}}" do
      patch(:hex_api_package, :search, fn _, _, _ -> {:ok, {403, %{}, "forbidden"}} end)
      assert {:error, {:http_status, 403}} = Api.search_packages(Repo.default(), "phoe")
    end

    test "propagates transport errors" do
      patch(:hex_api_package, :search, fn _, _, _ -> {:error, :nxdomain} end)
      assert {:error, :nxdomain} = Api.search_packages(Repo.default(), "phoe")
    end
  end

  describe "fetch_package/2" do
    test "delegates to :hex_api_package.get and returns the parsed body" do
      body = %{"name" => "phoenix", "releases" => [%{"version" => "1.7.14"}]}
      patch(:hex_api_package, :get, fn _config, _name -> {:ok, {200, %{}, body}} end)

      assert {:ok, ^body} = Api.fetch_package(Repo.default(), nil, "phoenix")
      assert_called(:hex_api_package.get(_config, "phoenix"))
    end

    test "passes config through unchanged" do
      patch(:hex_api_package, :get, fn config, _name ->
        send(self(), {:saw_config, config})
        {:ok, {200, %{}, %{"name" => "x"}}}
      end)

      org_config = Map.merge(Repo.default(), %{api_organization: "myorg", api_key: "tok"})
      Api.fetch_package(org_config, nil, "private_pkg")
      assert_received {:saw_config, %{api_organization: "myorg", api_key: "tok"}}
    end

    test "returns {:error, :empty_name} for an empty string without calling hex_core" do
      patch(:hex_api_package, :get, fn _, _ -> flunk("should not call hex_api_package") end)
      assert {:error, :empty_name} = Api.fetch_package(Repo.default(), nil, "")
    end

    test "routes self-hosted repos to :hex_repo.get_package and normalizes releases" do
      # Non-hexpm repos don't speak the /api/packages protocol; they only
      # serve the signed registry tarball via :hex_repo. The API should
      # transparently fetch through :hex_repo and present the same shape
      # callers expect from the hex.pm API path.
      patch(:hex_api_package, :get, fn _, _ -> flunk("should use :hex_repo for custom repos") end)

      patch(:hex_repo, :get_package, fn _config, "oban_pro" ->
        repo_data = %{
          name: "oban_pro",
          repository: "oban",
          releases: [
            %{version: "1.5.0", dependencies: [], inner_checksum: <<0>>, outer_checksum: <<0>>},
            %{version: "1.4.0", dependencies: [], inner_checksum: <<0>>, outer_checksum: <<0>>}
          ]
        }

        {:ok, {200, %{}, repo_data}}
      end)

      custom_repo_config =
        Map.merge(Repo.default(), %{
          repo_name: "oban",
          repo_url: "https://getoban.pro/repo",
          repo_key: "tok",
          repo_verify: true
        })

      assert {:ok, pkg} = Api.fetch_package(custom_repo_config, nil, "oban_pro")
      assert pkg["name"] == "oban_pro"
      assert Enum.map(pkg["releases"], & &1["version"]) == ["1.5.0", "1.4.0"]
    end

    test "still routes hexpm config to :hex_api_package.get (not the repo protocol)" do
      patch(:hex_repo, :get_package, fn _, _ -> flunk("should use :hex_api_package for hexpm") end)

      patch(:hex_api_package, :get, fn _, _ ->
        {:ok, {200, %{}, %{"name" => "phoenix", "releases" => []}}}
      end)

      assert {:ok, %{"name" => "phoenix"}} = Api.fetch_package(Repo.default(), nil, "phoenix")
    end

    test "translates 404s to {:error, {:http_status, 404}}" do
      patch(:hex_api_package, :get, fn _, _ -> {:ok, {404, %{}, "not found"}} end)
      assert {:error, {:http_status, 404}} = Api.fetch_package(Repo.default(), nil, "ghost")
    end
  end

  describe "fetch_releases/2" do
    test "always uses :hex_repo regardless of repo type (hexpm or custom)" do
      patch(:hex_api_package, :get, fn _, _ -> flunk("should not use :hex_api_package") end)

      patch(:hex_repo, :get_package, fn _config, "phoenix" ->
        {:ok,
         {200, %{},
          %{
            name: "phoenix",
            releases: [
              %{version: "1.7.14", dependencies: [], inner_checksum: <<0>>, outer_checksum: <<0>>}
            ]
          }}}
      end)

      assert {:ok, [release]} = Api.fetch_releases(Repo.default(), "phoenix")
      assert release["version"] == "1.7.14"
      assert release["retirement"] == nil
    end

    test "normalizes hex's retirement atoms into the short lowercase strings users see" do
      patch(:hex_repo, :get_package, fn _, _ ->
        releases =
          for {reason, expected} <- [
                {:RETIRED_INVALID, "invalid"},
                {:RETIRED_RENAMED, "renamed"},
                {:RETIRED_DEPRECATED, "deprecated"},
                {:RETIRED_SECURITY, "security"},
                {:RETIRED_OTHER, "other"}
              ] do
            %{
              version: "0.0.#{expected}",
              retired: %{reason: reason, message: "msg for " <> expected},
              dependencies: [],
              inner_checksum: <<0>>,
              outer_checksum: <<0>>
            }
          end

        {:ok, {200, %{}, %{name: "multi", releases: releases}}}
      end)

      {:ok, releases} = Api.fetch_releases(Repo.default(), "multi")

      assert Enum.map(releases, & &1["retirement"]["reason"]) ==
               ["invalid", "renamed", "deprecated", "security", "other"]

      assert Enum.all?(releases, fn r ->
               r["retirement"]["message"] == "msg for " <> r["retirement"]["reason"]
             end)
    end

    test "surfaces nil retirement for active releases" do
      patch(:hex_repo, :get_package, fn _, _ ->
        {:ok,
         {200, %{},
          %{
            name: "active",
            releases: [
              %{
                version: "1.0.0",
                retired: nil,
                dependencies: [],
                inner_checksum: <<0>>,
                outer_checksum: <<0>>
              }
            ]
          }}}
      end)

      assert {:ok, [%{"version" => "1.0.0", "retirement" => nil}]} =
               Api.fetch_releases(Repo.default(), "active")
    end

    test "returns {:error, :empty_name} for an empty package name" do
      patch(:hex_repo, :get_package, fn _, _ -> flunk("should not call :hex_repo") end)
      assert {:error, :empty_name} = Api.fetch_releases(Repo.default(), "")
    end

    test "translates non-2xx statuses to {:error, {:http_status, code}}" do
      patch(:hex_repo, :get_package, fn _, _ -> {:ok, {404, %{}, "not found"}} end)
      assert {:error, {:http_status, 404}} = Api.fetch_releases(Repo.default(), "ghost")
    end
  end
end
