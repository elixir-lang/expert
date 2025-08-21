defmodule Forge.Namespace.Path do
  alias Forge.Namespace

  def run(path, opts) when is_list(path) do
    path
    |> List.to_string()
    |> run(opts)
    |> String.to_charlist()
  end

  def run(path, opts) when is_binary(path) do
    apps = Keyword.fetch!(opts, :apps)

    path
    |> Path.split()
    |> Enum.map(fn path_component ->
      Enum.reduce(apps, path_component, fn app_name, path ->
        [path | vsn] = String.split(path, "-")

        if path == Atom.to_string(app_name) do
          new_path =
            app_name
            |> Namespace.Module.run(opts)
            |> Atom.to_string()

          rebuild_path(new_path, vsn)
        else
          rebuild_path(path, vsn)
        end
      end)
    end)
    |> Path.join()
  end

  defp rebuild_path(path, []), do: path

  defp rebuild_path(path, rest) do
    "#{path}-#{Enum.join(rest, "-")}"
  end
end
