defmodule Forge.Namespace.Transform.Apps do
  @moduledoc """
  Applies namespacing to all modules defined in .app files
  """

  alias Forge.Namespace

  def apply_to_all(base_directory, opts) do
    app_files_glob = Enum.join(opts[:apps], ",")

    base_directory
    |> Path.join("**/{#{app_files_glob}}.app")
    |> Path.wildcard()
    |> tap(fn app_files ->
      Mix.Shell.IO.info("Rewriting #{length(app_files)} app files")
    end)
    |> Enum.each(fn f -> run(f, opts) end)
  end

  def run(file_path, opts) do
    namespace_app = opts[:do_apps]

    with {:ok, app_definition} <- Namespace.Erlang.path_to_term(file_path),
         {:ok, converted} <- convert(app_definition, namespace_app, opts),
         :ok <- File.write(file_path, converted) do
      app_name =
        file_path
        |> Path.basename()
        |> Path.rootname()
        |> String.to_atom()

      if namespace_app do
        namespaced_app_name = Namespace.Module.run(app_name, opts)
        new_filename = "#{namespaced_app_name}.app"

        new_file_path =
          file_path
          |> Path.dirname()
          |> Path.join(new_filename)

        File.rename!(file_path, new_file_path)
      end
    end
  catch
    e ->
      Mix.Shell.IO.error("Failed to rename app file")
      reraise e, __STACKTRACE__
  end

  defp convert(app_definition, namespace_app, opts) do
    erlang_terms =
      app_definition
      |> visit(namespace_app, opts)
      |> Forge.Namespace.Erlang.term_to_string()

    {:ok, erlang_terms}
  end

  defp visit({:application, app_name, keys}, namespace_app, opts) do
    app =
      if namespace_app do
        Namespace.Module.run(app_name, opts)
      else
        app_name
      end

    {:application, app, Enum.map(keys, fn k -> visit(k, namespace_app, opts) end)}
  end

  defp visit({:applications, app_list} = original, namespace_app, opts) do
    if namespace_app do
      {:applications, Enum.map(app_list, fn app -> Namespace.Module.run(app, opts) end)}
    else
      original
    end
  end

  defp visit({:modules, module_list}, _, opts) do
    {:modules, Enum.map(module_list, fn app -> Namespace.Module.run(app, opts) end)}
  end

  defp visit({:description, desc}, _, _opts) do
    {:description, desc ++ ~c" namespaced by expert."}
  end

  defp visit({:mod, {module_name, args}}, _, opts) do
    {:mod, {Namespace.Module.run(module_name, opts), args}}
  end

  defp visit(key_value, _, _) do
    key_value
  end
end
