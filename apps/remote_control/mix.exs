defmodule Lexical.RemoteControl.MixProject do
  use Mix.Project
  Code.require_file("../../mix_includes.exs")

  def project do
    [
      app: :remote_control,
      version: "0.7.2",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: Mix.Dialyzer.config(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      preferred_cli_env: [benchmark: :test]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :sasl, :eex, :path_glob],
      mod: {Lexical.RemoteControl.Application, []}
    ]
  end

  # cli/0 is new for elixir 1.15, prior, we need to set `preferred_cli_env` in the project
  def cli do
    [
      preferred_envs: [benchmark: :test]
    ]
  end

  defp elixirc_paths(:test) do
    ~w(lib test/support)
  end

  defp elixirc_paths(_) do
    ~w(lib)
  end

  defp deps do
    [
      {:benchee, "~> 1.3", only: :test},
      {:common, path: "../common", env: Mix.env()},
      Mix.Credo.dependency(),
      Mix.Dialyzer.dependency(),
      {:elixir_sense,
       github: "elixir-lsp/elixir_sense", ref: "73ce7e0d239342fb9527d7ba567203e77dbb9b25"},
      {:patch, "~> 0.15", only: [:dev, :test], optional: true, runtime: false},
      {:path_glob, "~> 0.2", optional: true},
      {:phoenix_live_view, "~> 1.0", only: [:test], optional: true, runtime: false},
      {:sourceror, "~> 1.9"},
      {:stream_data, "~> 1.1", only: [:test], runtime: false},
      {:refactorex, "~> 0.1.51"}
    ]
  end

  defp aliases do
    [test: "test --no-start", benchmark: "run"]
  end
end
