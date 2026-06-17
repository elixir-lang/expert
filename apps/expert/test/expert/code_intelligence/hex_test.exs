defmodule Expert.CodeIntelligence.HexTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.CursorSupport

  alias Expert.CodeIntelligence.Hex
  alias Expert.CodeIntelligence.Hex.Api
  alias Expert.CodeIntelligence.Hex.Cache
  alias Expert.CodeIntelligence.Hex.Candidate
  alias Expert.EngineApi
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Project

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    start_supervised!({Cache, name: Cache, path: Path.join(tmp_dir, "cache.dets")})
    :ok
  end

  defp candidates(text) do
    {position, document} = pop_cursor(text, document: "mix.exs")
    analysis = Ast.analyze(document)
    Hex.candidates(analysis, position)
  end

  describe "candidates/2 in the package-name slot" do
    test "returns hex package candidates from the api with the default repo" do
      patch(Api, :search_packages, fn _config, "phoenix" ->
        {:ok,
         [
           %{
             "name" => "phoenix",
             "latest_stable_version" => "1.7.14",
             "meta" => %{"description" => "Productive web framework"},
             "downloads" => %{"all" => 100_000}
           }
         ]}
      end)

      assert [%Candidate.Package{} = pkg] =
               candidates(~S"""
               defmodule MyApp.MixProject do
                 use Mix.Project

                 defp deps do
                   [{:phoenix|, "~> 1.7"}]
                 end
               end
               """)

      assert pkg.name == "phoenix"
      assert pkg.latest_version == "1.7.14"
      assert pkg.description == "Productive web framework"

      assert_called(Api.search_packages(%{api_url: "https://hex.pm/api"}, "phoenix"))
    end

    test "returns no candidates when prefix is too short" do
      patch(Api, :search_packages, fn _config, _ -> flunk("api should not be called") end)

      assert [] =
               candidates(~S"""
               defmodule MyApp.MixProject do
                 defp deps do
                   [{:p|, "~> 1.7"}]
                 end
               end
               """)
    end

    test "returns no candidates when the dep references an unconfigured repo" do
      patch(Api, :search_packages, fn _, _ -> flunk("api should not be called") end)

      assert [] =
               candidates(~S"""
               defmodule MyApp.MixProject do
                 defp deps do
                   [{:phoenix|, "~> 1.7", repo: "internal_unknown"}]
                 end
               end
               """)
    end

    test "searches hex and returns candidates while the user is mid-typing a package name" do
      search_calls = self()

      patch(Api, :search_packages, fn config, query ->
        send(search_calls, {:search, config, query})

        {:ok,
         [
           %{
             "name" => "phoenix",
             "latest_stable_version" => "1.7.14",
             "meta" => %{"description" => "Productive web framework"}
           },
           %{
             "name" => "phoenix_live_view",
             "latest_stable_version" => "1.0.0",
             "meta" => %{"description" => "LiveView bindings for Phoenix"}
           }
         ]}
      end)

      candidates =
        candidates(~S"""
        defmodule Grove.MixProject do
          use Mix.Project

          defp deps do
            [
              {:phoen|
              {:circuits_uart, "~> 1.5"}
            ]
          end
        end
        """)

      assert_received {:search, _config, "phoen"}

      assert [%Candidate.Package{name: "phoenix"}, %Candidate.Package{name: "phoenix_live_view"}] =
               candidates
    end
  end

  describe "candidates/2 in the version slot" do
    test "returns exact releases sorted newest-first by semver" do
      patch(Api, :fetch_releases, fn _config, "phoenix" ->
        {:ok,
         [
           %{"version" => "1.7.0", "retirement" => nil},
           %{"version" => "1.7.14", "retirement" => nil},
           %{"version" => "1.7.9", "retirement" => nil}
         ]}
      end)

      versions =
        ~S"""
        defmodule MyApp.MixProject do
          defp deps do
            [{:phoenix, "~> 1.|"}]
          end
        end
        """
        |> candidates()
        |> Enum.map(& &1.version)

      assert versions == ["1.7.14", "1.7.9", "1.7.0"]
    end

    test "interleaves pre-releases with stable releases in semver order" do
      patch(Api, :fetch_releases, fn _config, "phoenix" ->
        {:ok,
         [
           %{"version" => "1.7.14", "retirement" => nil},
           %{"version" => "1.7.0-rc.1", "retirement" => nil},
           %{"version" => "1.6.16", "retirement" => nil},
           %{"version" => "1.6.0", "retirement" => nil},
           %{"version" => "1.5.0-rc.2", "retirement" => nil},
           %{"version" => "1.5.0-rc.1", "retirement" => nil}
         ]}
      end)

      versions =
        ~S"""
        defmodule MyApp.MixProject do
          defp deps do
            [{:phoenix, "~> 1.|"}]
          end
        end
        """
        |> candidates()
        |> Enum.map(& &1.version)

      assert versions == [
               "1.7.14",
               "1.7.0-rc.1",
               "1.6.16",
               "1.6.0",
               "1.5.0-rc.2",
               "1.5.0-rc.1"
             ]
    end

    test "caps exact versions at the newest 50 for packages with long release histories" do
      releases =
        for minor <- 3..0//-1, patch <- 29..0//-1 do
          %{"version" => "1.#{minor}.#{patch}", "retirement" => nil}
        end

      patch(Api, :fetch_releases, fn _config, "phoenix" -> {:ok, releases} end)

      versions =
        ~S"""
        defmodule MyApp.MixProject do
          defp deps do
            [{:phoenix, "~> 1.|"}]
          end
        end
        """
        |> candidates()
        |> Enum.map(& &1.version)

      assert length(versions) == 50
      assert List.first(versions) == "1.3.29"
      assert List.last(versions) == "1.2.10"
      refute Enum.any?(versions, &String.starts_with?(&1, "~>"))
    end

    test "filters by the user's trailing version-like prefix so major-series queries narrow" do
      patch(Api, :fetch_releases, fn _config, "phoenix" ->
        {:ok,
         [
           %{"version" => "3.0.0", "retirement" => nil},
           %{"version" => "2.19.2", "retirement" => nil},
           %{"version" => "2.18.0", "retirement" => nil},
           %{"version" => "1.7.0", "retirement" => nil}
         ]}
      end)

      versions =
        ~S"""
        defmodule MyApp.MixProject do
          defp deps do
            [{:phoenix, "~> 2.|"}]
          end
        end
        """
        |> candidates()
        |> Enum.map(& &1.version)

      assert versions == ["2.19.2", "2.18.0"]
    end

    test "returns the full release list when the prefix has no trailing version chars" do
      patch(Api, :fetch_releases, fn _config, "phoenix" ->
        {:ok,
         [
           %{"version" => "3.0.0", "retirement" => nil},
           %{"version" => "2.19.2", "retirement" => nil},
           %{"version" => "1.7.0", "retirement" => nil}
         ]}
      end)

      versions =
        ~S"""
        defmodule MyApp.MixProject do
          defp deps do
            [{:phoenix, "~>|"}]
          end
        end
        """
        |> candidates()
        |> Enum.map(& &1.version)

      assert versions == ["3.0.0", "2.19.2", "1.7.0"]
    end

    test "filters by raw version prefix without any operator" do
      patch(Api, :fetch_releases, fn _config, "phoenix" ->
        {:ok,
         [
           %{"version" => "1.7.14", "retirement" => nil},
           %{"version" => "1.7.9", "retirement" => nil},
           %{"version" => "1.6.16", "retirement" => nil}
         ]}
      end)

      versions =
        ~S"""
        defmodule MyApp.MixProject do
          defp deps do
            [{:phoenix, "1.7|"}]
          end
        end
        """
        |> candidates()
        |> Enum.map(& &1.version)

      assert versions == ["1.7.14", "1.7.9"]
    end

    test "threads hex retirement metadata through to Candidate.Version" do
      patch(Api, :fetch_releases, fn _config, "ash" ->
        {:ok,
         [
           %{"version" => "3.0.0", "retirement" => nil},
           %{
             "version" => "2.19.2",
             "retirement" => %{
               "reason" => "invalid",
               "message" => "soft destroys not honored"
             }
           },
           %{"version" => "2.18.0", "retirement" => nil}
         ]}
      end)

      cands =
        candidates(~S"""
        defmodule MyApp.MixProject do
          defp deps do
            [{:ash, "~> |"}]
          end
        end
        """)

      by_version = Map.new(cands, fn c -> {c.version, c} end)

      assert by_version["3.0.0"].retirement == nil
      assert by_version["2.18.0"].retirement == nil

      assert %{reason: "invalid", message: "soft destroys not honored"} =
               by_version["2.19.2"].retirement
    end

    test "returns no candidates when the dep references an unconfigured repo" do
      patch(Api, :fetch_releases, fn _, _ -> flunk("api should not be called") end)

      assert [] =
               candidates(~S"""
               defmodule MyApp.MixProject do
                 defp deps do
                   [{:phoenix, "~> 1.|", repo: "internal_unknown"}]
                 end
               end
               """)
    end

    test "filters versions with >= operator prefix" do
      patch(Api, :fetch_releases, fn _config, "phoenix" ->
        {:ok,
         [
           %{"version" => "2.0.0", "retirement" => nil},
           %{"version" => "1.7.14", "retirement" => nil},
           %{"version" => "1.6.0", "retirement" => nil}
         ]}
      end)

      versions =
        ~S"""
        defmodule MyApp.MixProject do
          defp deps do
            [{:phoenix, ">= 1.|"}]
          end
        end
        """
        |> candidates()
        |> Enum.map(& &1.version)

      assert versions == ["1.7.14", "1.6.0"]
    end

    test "filters versions with == operator prefix" do
      patch(Api, :fetch_releases, fn _config, "phoenix" ->
        {:ok,
         [
           %{"version" => "2.0.0", "retirement" => nil},
           %{"version" => "1.7.14", "retirement" => nil}
         ]}
      end)

      versions =
        ~S"""
        defmodule MyApp.MixProject do
          defp deps do
            [{:phoenix, "== 2.|"}]
          end
        end
        """
        |> candidates()
        |> Enum.map(& &1.version)

      assert versions == ["2.0.0"]
    end

    test "returns no candidates for complex or/and requirements" do
      patch(Api, :fetch_releases, fn _config, "phoenix" ->
        {:ok,
         [
           %{"version" => "2.0.0", "retirement" => nil},
           %{"version" => "1.7.14", "retirement" => nil}
         ]}
      end)

      assert [] =
               candidates(~S"""
               defmodule MyApp.MixProject do
                 defp deps do
                   [{:phoenix, ">= 1.0 and < 2.0|"}]
                 end
               end
               """)
    end

    test "preserves the operator in the candidate prefix for text-edit calculation" do
      patch(Api, :fetch_releases, fn _config, "phoenix" ->
        {:ok, [%{"version" => "1.7.14", "retirement" => nil}]}
      end)

      [candidate] =
        candidates(~S"""
        defmodule MyApp.MixProject do
          defp deps do
            [{:phoenix, ">= 1.|"}]
          end
        end
        """)

      assert candidate.version == "1.7.14"
      assert candidate.prefix == ">= 1."
    end
  end

  describe "candidates/2 in the opts slot" do
    test "returns Mix.Project keyword opts filtered by prefix" do
      patch(Api, :search_packages, fn _, _ -> flunk("api should not be called") end)
      patch(Api, :fetch_package, fn _, _, _ -> flunk("api should not be called") end)
      patch(Api, :fetch_releases, fn _, _ -> flunk("api should not be called") end)

      assert opts =
               candidates(~S"""
               defmodule MyApp.MixProject do
                 defp deps do
                   [{:phoenix, "~> 1.7", on|}]
                 end
               end
               """)

      assert Enum.any?(opts, &match?(%Candidate.Opt{name: "only"}, &1))
      assert Enum.all?(opts, fn %Candidate.Opt{name: name} -> String.starts_with?(name, "on") end)
    end
  end

  describe "candidates/2 outside of deps" do
    test "returns []" do
      patch(Api, :search_packages, fn _, _ -> flunk("api should not be called") end)

      assert [] =
               candidates(~S"""
               defmodule MyApp do
                 def hello, do: :wo|rld
               end
               """)
    end
  end

  describe "project_file?/2" do
    defp unique_project do
      dir = Path.join(System.tmp_dir!(), "hex_gate_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      project = dir |> Document.Path.to_uri() |> Project.new()
      {project, dir}
    end

    test "returns false without a project" do
      refute Hex.project_file?(nil, "/tmp/anything/mix.exs")
    end

    test "returns false when the document has no path" do
      {project, _dir} = unique_project()
      patch(EngineApi, :call, fn _, Engine.Deps, :project_files, [] -> [] end)
      refute Hex.project_file?(project, %Document{path: nil})
    end

    test "returns true for the root project file" do
      {project, dir} = unique_project()
      mix_exs = Path.join(dir, "mix.exs")

      patch(EngineApi, :call, fn _, Engine.Deps, :project_files, [] -> [mix_exs] end)

      assert Hex.project_file?(project, mix_exs)
    end

    test "returns true for each umbrella child's project file" do
      {project, dir} = unique_project()
      root_mix = Path.join(dir, "mix.exs")
      child_a = Path.join([dir, "apps", "a", "mix.exs"])
      child_b = Path.join([dir, "apps", "b", "mix.exs"])

      patch(EngineApi, :call, fn _, Engine.Deps, :project_files, [] ->
        [root_mix, child_a, child_b]
      end)

      assert Hex.project_file?(project, root_mix)
      assert Hex.project_file?(project, child_a)
      assert Hex.project_file?(project, child_b)
    end

    test "returns false for non-project files in the same tree" do
      {project, dir} = unique_project()
      mix_exs = Path.join(dir, "mix.exs")

      patch(EngineApi, :call, fn _, Engine.Deps, :project_files, [] -> [mix_exs] end)

      refute Hex.project_file?(project, Path.join(dir, "lib/my_app.ex"))
      refute Hex.project_file?(project, Path.join(dir, "config/config.exs"))
    end

    test "memoizes the engine RPC result across calls for the same project" do
      {project, dir} = unique_project()
      mix_exs = Path.join(dir, "mix.exs")
      counter = :counters.new(1, [])

      patch(EngineApi, :call, fn _, Engine.Deps, :project_files, [] ->
        :counters.add(counter, 1, 1)
        [mix_exs]
      end)

      assert Hex.project_file?(project, mix_exs)
      assert Hex.project_file?(project, mix_exs)
      assert Hex.project_file?(project, mix_exs)

      assert :counters.get(counter, 1) == 1
    end

    test "does not memoize an empty result — retries on subsequent calls" do
      {project, dir} = unique_project()
      mix_exs = Path.join(dir, "mix.exs")
      counter = :counters.new(1, [])

      patch(EngineApi, :call, fn _, Engine.Deps, :project_files, [] ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        # First call: engine not ready yet.
        # Subsequent calls: engine returns the real list.
        if n == 0, do: [], else: [mix_exs]
      end)

      refute Hex.project_file?(project, mix_exs)
      assert Hex.project_file?(project, mix_exs)
      assert Hex.project_file?(project, mix_exs)

      assert :counters.get(counter, 1) == 2
    end
  end

  describe "installed_version/2" do
    test "returns nil without a project context" do
      refute Hex.installed_version(nil, "phoenix")
    end

    test "returns the version reported by the engine's Application.spec lookup" do
      project = %Project{}

      patch(EngineApi, :call, fn _, Engine.Deps, :dep_version, ["phoenix"] ->
        {:ok, "1.7.14"}
      end)

      assert Hex.installed_version(project, "phoenix") == "1.7.14"
    end

    test "returns nil when the engine reports the dep is not loaded" do
      project = %Project{}

      patch(EngineApi, :call, fn _, Engine.Deps, :dep_version, ["phoenix"] ->
        :error
      end)

      refute Hex.installed_version(project, "phoenix")
    end
  end

  describe "candidates_for_context/2" do
    test "dispatches :name slot to a network-backed package search" do
      patch(Api, :search_packages, fn _config, "phoe" ->
        {:ok,
         [
           %{"name" => "phoenix", "meta" => %{"description" => "Web framework"}},
           %{"name" => "phoenix_pubsub", "meta" => %{"description" => "Pub/Sub"}}
         ]}
      end)

      assert [%Candidate.Package{name: "phoenix"}, %Candidate.Package{name: "phoenix_pubsub"}] =
               Hex.candidates_for_context(
                 %{slot: :name, prefix: "phoe", package: nil, repo: "hexpm"},
                 nil
               )
    end

    test "dispatches :version slot to fetch_releases and builds Candidate.Version entries" do
      patch(Api, :fetch_releases, fn _config, "phoenix" ->
        {:ok,
         [
           %{"version" => "1.7.14", "retirement" => nil},
           %{"version" => "1.7.13", "retirement" => nil}
         ]}
      end)

      assert [
               %Candidate.Version{version: "1.7.14", package: "phoenix"},
               %Candidate.Version{version: "1.7.13", package: "phoenix"}
             ] =
               Hex.candidates_for_context(
                 %{slot: :version, prefix: "~> 1.", package: "phoenix", repo: "hexpm"},
                 nil
               )
    end

    test "dispatches :opts slot to the static opt list without any network calls" do
      patch(Api, :search_packages, fn _, _ -> flunk("should not touch the network") end)
      patch(Api, :fetch_releases, fn _, _ -> flunk("should not touch the network") end)

      assert opts =
               Hex.candidates_for_context(
                 %{slot: :opts, prefix: "on", package: "phoenix", repo: "hexpm"},
                 nil
               )

      assert Enum.any?(opts, &match?(%Candidate.Opt{name: "only"}, &1))
      assert Enum.all?(opts, fn %Candidate.Opt{name: name} -> String.starts_with?(name, "on") end)
    end

    test "returns [] for an unrecognized context shape" do
      assert [] = Hex.candidates_for_context(%{slot: :made_up}, nil)
    end
  end
end
