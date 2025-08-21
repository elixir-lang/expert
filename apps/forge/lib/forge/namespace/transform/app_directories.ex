defmodule Forge.Namespace.Transform.AppDirectories do
  alias Forge.Namespace

  def apply_to_all(base_directory, opts) do
    app_globs = Enum.join(opts[:apps], "*,")

    base_directory
    |> Path.join("lib/{#{app_globs}*}")
    |> Path.wildcard()
    |> Enum.each(fn d -> run(d, opts) end)
  end

  def run(app_path, opts) do
    namespaced_app_path = Namespace.Path.run(app_path, opts)

    with true <- app_path != namespaced_app_path,
         {:ok, _} <- File.rm_rf(namespaced_app_path) do
      File.rename!(app_path, namespaced_app_path)
    end
  end
end
