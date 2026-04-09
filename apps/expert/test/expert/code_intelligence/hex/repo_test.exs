defmodule Expert.CodeIntelligence.Hex.RepoTest do
  use ExUnit.Case, async: false
  use Patch

  alias Expert.CodeIntelligence.Hex.Repo
  alias Expert.EngineApi
  alias Forge.Project

  # All repo lookups flow through `Engine.Deps.get_repo/1` via an
  # RPC to the project's engine node. Tests mock `EngineApi.call/4` to
  # return whatever shape `Hex.Repo.get_repo/1` would produce for that
  # repo — atom-keyed maps with `:url`, `:auth_key`, `:public_key`,
  # etc. — so the assertions here verify the `:hex_core` config we
  # assemble from that shape, not the file-parsing logic (which no
  # longer exists in Expert's process).

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
      # Without a project we can't RPC to the engine, so organization
      # repos are unresolvable — this matches how `hex` itself would
      # fail outside a Mix session.
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
      # Self-hosted repos go through the repo protocol
      # (`:hex_repo.get_package`), NOT the `/api/packages` endpoint.
      assert config[:repo_url] == "https://hex.internal.example/repo"
      assert config[:repo_name] == "internal"
      assert config[:repo_key] == "tok-int-789"
      assert config[:repo_verify] == true
      assert config[:repo_public_key] =~ "BEGIN PUBLIC KEY"
      # `api_url` is left at the hex.pm default — self-hosted repos
      # don't speak the API protocol, so any code path that would hit
      # it is a bug.
      assert config[:api_url] == "https://hex.pm/api"
    end

    test "still populates repo_* fields when hex.config has no public_key",
         %{project: project} do
      mock_engine_repo("internal", %{
        url: "https://hex.internal.example/repo",
        auth_key: "tok-int-789"
      })

      assert {:ok, config} = Repo.resolve("internal", project: project)
      assert config[:repo_url] == "https://hex.internal.example/repo"
      assert config[:repo_key] == "tok-int-789"
      # `repo_public_key` falls back to hex.pm's default (from
      # `:hex_core.default_config/0`).
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
      # Self-hosted repos are entirely unresolvable without a project —
      # the engine RPC is the only path and it requires a Project.
      assert :error = Repo.resolve("internal", [])
    end

    test "returns :error when the engine RPC crashes", %{project: project} do
      patch(EngineApi, :call, fn _project, Engine.Deps, :get_repo, ["internal"] ->
        raise "rpc died"
      end)

      assert :error = Repo.resolve("internal", project: project)
    end
  end
end
