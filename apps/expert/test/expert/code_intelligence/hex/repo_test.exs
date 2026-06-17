defmodule Expert.CodeIntelligence.Hex.RepoTest do
  use ExUnit.Case, async: false
  use Patch

  alias Expert.CodeIntelligence.Hex.Repo
  alias Expert.EngineApi
  alias Forge.Project

  setup do
    %{project: %Project{}}
  end

  defp mock_engine_repo(name, entry) do
    patch(EngineApi, :call, fn _project, Engine.Deps, :get_repo, [^name] ->
      {:ok, entry}
    end)
  end

  defp mock_engine_unknown(name) do
    patch(EngineApi, :call, fn _project, Engine.Deps, :get_repo, [^name] ->
      :error
    end)
  end

  describe "default/0" do
    test "returns the hex_core public hex.pm config" do
      config = Repo.default()
      assert config[:api_url] == "https://hex.pm/api"
      assert config[:repo_name] == "hexpm"
      assert config[:api_organization] == :undefined
      assert config[:api_key] == :undefined
    end
  end

  describe "resolve/2 for the default repo" do
    test "returns the default config without touching the engine", %{project: project} do
      patch(EngineApi, :call, fn _, _, _, _ -> flunk("engine should not be called for hexpm") end)

      assert {:ok, config} = Repo.resolve("hexpm", project: project)
      assert config[:api_url] == "https://hex.pm/api"
      assert config[:repo_url] == "https://repo.hex.pm"
      assert config[:api_key] == :undefined
    end

    test "works even without a project for the plain hexpm repo" do
      assert {:ok, config} = Repo.resolve("hexpm", [])
      assert config[:api_url] == "https://hex.pm/api"
    end
  end

  describe "resolve/2 for a hexpm organization" do
    test "merges api_organization and api_key from the engine's hex config",
         %{project: project} do
      mock_engine_repo("hexpm:myorg", %{auth_key: "tok-org-123"})

      assert {:ok, config} = Repo.resolve("hexpm:myorg", project: project)
      assert config[:api_url] == "https://hex.pm/api"
      assert config[:api_organization] == "myorg"
      assert config[:api_key] == "tok-org-123"
    end

    test "returns :error when the engine reports the org is not configured",
         %{project: project} do
      mock_engine_unknown("hexpm:myorg")
      assert :error = Repo.resolve("hexpm:myorg", project: project)
    end

    test "returns :error when the org has no auth key", %{project: project} do
      mock_engine_repo("hexpm:myorg", %{})
      assert :error = Repo.resolve("hexpm:myorg", project: project)
    end

    test "returns :error when there is no project context" do
      assert :error = Repo.resolve("hexpm:myorg", [])
    end
  end

  describe "resolve/2 for a self-hosted repo" do
    test "populates repo_* fields so :hex_repo can fetch + verify the registry",
         %{project: project} do
      mock_engine_repo("internal", %{
        url: "https://hex.internal.example/repo",
        auth_key: "tok-int-789",
        public_key: "-----BEGIN PUBLIC KEY-----\nAAA\n-----END PUBLIC KEY-----\n"
      })

      assert {:ok, config} = Repo.resolve("internal", project: project)
      assert config[:repo_url] == "https://hex.internal.example/repo"
      assert config[:repo_name] == "internal"
      assert config[:repo_key] == "tok-int-789"
      assert config[:repo_verify] == true
      assert config[:repo_public_key] =~ "BEGIN PUBLIC KEY"
      assert config[:api_url] == "https://hex.pm/api"
    end

    test "populates repo_* fields when hex.config has no public_key",
         %{project: project} do
      mock_engine_repo("internal", %{
        url: "https://hex.internal.example/repo",
        auth_key: "tok-int-789"
      })

      assert {:ok, config} = Repo.resolve("internal", project: project)
      assert config[:repo_url] == "https://hex.internal.example/repo"
      assert config[:repo_key] == "tok-int-789"
      refute is_nil(config[:repo_public_key])
    end

    test "treats a missing `url` in the repo entry as :error",
         %{project: project} do
      mock_engine_repo("internal", %{auth_key: "tok-only"})
      assert :error = Repo.resolve("internal", project: project)
    end

    test "returns :error when the engine reports the repo is not configured",
         %{project: project} do
      mock_engine_unknown("internal")
      assert :error = Repo.resolve("internal", project: project)
    end

    test "returns :error when there is no project context" do
      assert :error = Repo.resolve("internal", [])
    end
  end
end
