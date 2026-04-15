defmodule Expert.CodeIntelligence.Hex.HoverTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.CursorSupport

  alias Expert.CodeIntelligence.Hex.Api
  alias Expert.CodeIntelligence.Hex.Cache
  alias Expert.CodeIntelligence.Hex.Hover
  alias Expert.EngineApi
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Project

  setup do
    path = Path.join(System.tmp_dir!(), "hex_hover_#{System.unique_integer([:positive])}.dets")
    on_exit(fn -> File.rm(path) end)
    start_supervised!({Cache, name: Cache, path: path})
    :ok
  end

  defp content(text, project \\ nil) do
    {position, document} = pop_cursor(text, document: "mix.exs")
    analysis = Ast.analyze(document)
    Hover.content(analysis, position, project)
  end

  test "renders hex package metadata when cursor is on a deps package atom" do
    patch(Api, :fetch_package, fn _config, _project, "phoenix" ->
      {:ok,
       %{
         "name" => "phoenix",
         "latest_stable_version" => "1.7.14",
         "meta" => %{
           "description" => "Productive web framework",
           "licenses" => ["MIT"]
         },
         "downloads" => %{"all" => 1_500_000},
         "html_url" => "https://hex.pm/packages/phoenix",
         "docs_html_url" => "https://hexdocs.pm/phoenix/"
       }}
    end)

    assert {:ok, markdown} =
             content(~S"""
             defmodule MyApp.MixProject do
               defp deps do
                 [{:pho|enix, "~> 1.7"}]
               end
             end
             """)

    assert markdown =~ "## phoenix"
    assert markdown =~ "Productive web framework"
    assert markdown =~ "**Latest:** `1.7.14`"
    assert markdown =~ "**License:** MIT"
    assert markdown =~ "1.5M"
    assert markdown =~ "[hexdocs](https://hexdocs.pm/phoenix/)"
  end

  test "renders installed version + update-available hint when project reports a lower version" do
    patch(Api, :fetch_package, fn _config, _project, "phoenix" ->
      {:ok,
       %{
         "name" => "phoenix",
         "latest_stable_version" => "1.7.14",
         "meta" => %{"description" => "Web framework"}
       }}
    end)

    patch(EngineApi, :call, fn _project, Engine.Deps, :dep_version, ["phoenix"] ->
      {:ok, "1.7.10"}
    end)

    project = System.tmp_dir!() |> Document.Path.to_uri() |> Project.new()

    assert {:ok, markdown} =
             content(
               ~S"""
               defmodule MyApp.MixProject do
                 defp deps do
                   [{:pho|enix, "~> 1.7"}]
                 end
               end
               """,
               project
             )

    assert markdown =~ "**Installed:** `1.7.10` _(update available: `1.7.14`)_"
  end

  test "renders up-to-date hint when installed version matches latest" do
    patch(Api, :fetch_package, fn _config, _project, "phoenix" ->
      {:ok,
       %{
         "name" => "phoenix",
         "latest_stable_version" => "1.7.14",
         "meta" => %{"description" => "Web framework"}
       }}
    end)

    patch(EngineApi, :call, fn _project, Engine.Deps, :dep_version, ["phoenix"] ->
      {:ok, "1.7.14"}
    end)

    project = System.tmp_dir!() |> Document.Path.to_uri() |> Project.new()

    assert {:ok, markdown} =
             content(
               ~S"""
               defmodule MyApp.MixProject do
                 defp deps do
                   [{:pho|enix, "~> 1.7"}]
                 end
               end
               """,
               project
             )

    assert markdown =~ "**Installed:** `1.7.14` _(up to date)_"
  end

  test "omits the installed line when the engine reports the dep is not loaded" do
    patch(Api, :fetch_package, fn _config, _project, "phoenix" ->
      {:ok,
       %{
         "name" => "phoenix",
         "latest_stable_version" => "1.7.14",
         "meta" => %{"description" => "Web framework"}
       }}
    end)

    patch(EngineApi, :call, fn _project, Engine.Deps, :dep_version, ["phoenix"] ->
      :error
    end)

    project = System.tmp_dir!() |> Document.Path.to_uri() |> Project.new()

    assert {:ok, markdown} =
             content(
               ~S"""
               defmodule MyApp.MixProject do
                 defp deps do
                   [{:pho|enix, "~> 1.7"}]
                 end
               end
               """,
               project
             )

    refute markdown =~ "**Installed:**"
    assert markdown =~ "**Latest:** `1.7.14`"
    refute markdown =~ "update available"
    refute markdown =~ "up to date"
  end

  test "returns :error when cursor is not on a deps package" do
    patch(Api, :fetch_package, fn _, _, _ -> flunk("api should not be called") end)

    assert :error =
             content(~S"""
             defmodule MyApp do
               def hello, do: :wo|rld
             end
             """)
  end

  test "degrades gracefully for self-hosted repo packages with only a name" do
    # `:hex_repo.get_package/2` returns releases + dependencies but not
    # the metadata fields hex.pm's API exposes (description, license,
    # downloads, html_url). For a dep like `{:oban_pro, "~> 1.5",
    # repo: "oban"}`, we still want the hover to render — just with the
    # package heading and nothing else, since the rest of the sections
    # correctly filter themselves out via `blank?/1`.
    #
    # Self-hosted repo resolution runs through an RPC to the project's
    # engine node, so we mock both `EngineApi.call/4` (returning a fake
    # hex repo entry for "oban") and `Api.fetch_package/2` (returning
    # the sparse shape `:hex_repo.get_package/2` normalizes to).
    patch(EngineApi, :call, fn _project, Engine.Deps, :get_repo, ["oban"] ->
      {:ok,
       %{
         url: "https://getoban.pro/repo",
         auth_key: "tok",
         public_key: "-----BEGIN PUBLIC KEY-----\nAAA\n-----END PUBLIC KEY-----\n"
       }}
    end)

    patch(Api, :fetch_package, fn _config, _project, "oban_pro" ->
      {:ok,
       %{
         "name" => "oban_pro",
         "releases" => [%{"version" => "1.5.0"}]
       }}
    end)

    project = System.tmp_dir!() |> Document.Path.to_uri() |> Project.new()

    assert {:ok, markdown} =
             content(
               ~S"""
               defmodule MyApp.MixProject do
                 defp deps do
                   [{:oban|_pro, "~> 1.5", repo: "oban"}]
                 end
               end
               """,
               project
             )

    # Only the heading survives the empty-metadata filtering. This
    # documents the expected degradation for custom repos: no links,
    # no downloads, no license, no description — but the hover still
    # opens and tells the user which package they're looking at.
    assert String.trim(markdown) == "## oban_pro"
  end

  test "returns :error when cursor is in version slot" do
    patch(Api, :fetch_package, fn _, _, _ -> flunk("api should not be called") end)

    assert :error =
             content(~S"""
             defmodule MyApp.MixProject do
               defp deps do
                 [{:phoenix, "~> 1.|"}]
               end
             end
             """)
  end
end
