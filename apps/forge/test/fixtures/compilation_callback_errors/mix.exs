defmodule CompilationCallbackErrors.MixProject do
  use Mix.Project

  def project do
    Code.put_compiler_option(:ignore_module_conflict, true)

    [
      app: :compilation_callback_errors,
      version: "0.1.0",
      elixir: "~> 1.15",
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
