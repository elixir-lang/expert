defmodule Expert.MixProject do
  use Mix.Project
  Code.require_file("../../mix_includes.exs")

  def project do
    [
      app: :expert,
      version: "0.7.2",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: Mix.Dialyzer.config(add_apps: [:jason]),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :kernel, :erts],
      mod: {Expert.Application, []}
    ]
  end

  def aliases do
    [
      compile: "compile --docs --debug-info",
      docs: "docs --html",
      test: "test --no-start"
    ]
  end

  defp elixirc_paths(:test) do
    ["lib", "test/support"]
  end

  defp elixirc_paths(_) do
    ["lib"]
  end

  defp deps do
    [
      Mix.Credo.dependency(),
      Mix.Dialyzer.dependency(),
      {:engine, path: "../engine", env: Mix.env()},
      {:forge, path: "../forge", env: Mix.env()},
      {:gen_lsp, "~> 0.11"},
      {:jason, "~> 1.4"},
      {:logger_file_backend, "~> 0.0", only: [:dev, :prod]},
      {:patch, "~> 0.15", runtime: false, only: [:dev, :test]},
      {:path_glob, "~> 0.2"},
      {:schematic, "~> 0.2"},
      {:sourceror, "~> 1.9"}
    ]
  end
end
