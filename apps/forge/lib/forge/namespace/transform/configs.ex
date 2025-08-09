defmodule Forge.Namespace.Transform.Configs do
  def apply_to_all(base_directory, opts) do
    base_directory
    |> Path.join("**/runtime.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.absname/1)
    |> tap(fn paths ->
      Mix.Shell.IO.info("Rewriting #{length(paths)} config scripts.")
    end)
    |> Enum.each(&run(&1, opts))
  end

  def run(path, opts) do
    namespaced =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.postwalk(fn
        {:__aliases__, meta, alias} ->
          namespaced_alias =
            alias
            |> Module.concat()
            |> Forge.Namespace.Module.run(opts)
            |> Module.split()
            |> Enum.map(&String.to_atom/1)

          {:__aliases__, meta, namespaced_alias}

        atom when is_atom(atom) ->
          Forge.Namespace.Module.run(atom, opts)

        ast ->
          ast
      end)
      |> Macro.to_string()

    File.write!(path, namespaced)
  end
end
