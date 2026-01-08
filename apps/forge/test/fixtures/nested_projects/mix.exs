defmodule NestedProjects.MixProject do
  use Mix.Project

  def project do
    Code.put_compiler_option(:ignore_module_conflict, true)

    [
      app: :nested_projects,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end
end
