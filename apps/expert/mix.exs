defmodule Expert.MixProject do
  use Mix.Project
  Code.require_file("../../mix_includes.exs")

  def project do
    [
      app: :expert,
      version: "0.7.2",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: Mix.Dialyzer.config(add_apps: [:jason]),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :kernel, :erts, :observer],
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

  defp releases() do
    [
      expert: [
        strip_beams: false,
        cookie: "expert",
        steps: release_steps(),
        burrito: [
          targets: [
            darwin_arm64: [os: :darwin, cpu: :aarch64],
            darwin_amd64: [os: :darwin, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            linux_amd64: [os: :linux, cpu: :x86_64],
            windows_amd64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp release_steps() do
    [
      :assemble,
      &Expert.Release.assemble/1,
      &Burrito.wrap/1
    ]
  end

  defp deps do
    [
      {:burrito, "~> 1.3", only: [:dev, :prod]},
      Mix.Credo.dependency(),
      Mix.Dialyzer.dependency(),
      # In practice Expert does not hardly depend on Engine, only on its compiled
      # artifacts, but we need it as a test dependency to set up tests that
      # assume a roundtrip to a project node is made.
      {:engine, path: "../engine", env: Mix.env(), only: [:test]},
      {:forge, path: "../forge", env: Mix.env()},
      {:gen_lsp, github: "elixir-tools/gen_lsp", branch: "async"},
      {:jason, "~> 1.4"},
      {:logger_file_backend, "~> 0.0", only: [:dev, :prod]},
      {:patch, "~> 0.15", runtime: false, only: [:dev, :test]},
      {:path_glob, "~> 0.2"},
      {:schematic, "~> 0.2"},
      {:sourceror, "~> 1.9"}
    ]
  end
end
