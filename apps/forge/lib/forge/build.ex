defmodule Mix.Tasks.Build do
  use Mix.Task

  def run(_args) do
    Mix.Task.run("compile", [])

    namespaced_dir = "_build/#{Mix.env()}_ns"

    # Remove the existing namespaced dir
    File.rm_rf(namespaced_dir)
    # Create our namespaced area
    File.mkdir_p(namespaced_dir)

    # Move our build artifacts from safekeeping to the build area
    File.cp_r!("_build/#{Mix.env()}", namespaced_dir)

    # Namespace the new code
    Mix.Task.run(:namespace, [
      namespaced_dir
    ])
  end
end
