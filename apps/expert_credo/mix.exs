defmodule ExpertCredo.MixProject do
  use Mix.Project
  Code.require_file("../../mix_dialyzer.exs")
  @repo_url "https://github.com/elixir-lang/expert/"
  @version "0.1.0"

  def project do
    [
      app: :expert_credo,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      dialyzer: Mix.Dialyzer.config(add_apps: [:jason])
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      env: [expert_plugin: true]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:forge, path: "../forge"},
      {:credo, "> 0.0.0", only: [:dev, :test]},
      {:deps_nix, "~> 2.4", only: :dev},
      Mix.Dialyzer.dependency(),
      {:jason, "> 0.0.0", optional: true},
      {:ex_doc, "~> 0.34", optional: true, only: [:dev, :hex]}
    ]
  end

  defp docs do
    [
      extras: ["README.md": [title: "Overview"]],
      main: "readme",
      homepage_url: @repo_url,
      source_ref: "v#{@version}",
      source_url: @repo_url
    ]
  end
end
