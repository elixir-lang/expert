defmodule Forge.Namespace.Transform.Scripts do
  @moduledoc """
  A transform that updates any module in .script and .rel files with namespaced versions
  """

  def apply_to_all(base_directory, opts) do
    base_directory
    |> find_scripts()
    |> tap(fn script_files ->
      Mix.Shell.IO.info("Rewriting #{length(script_files)} scripts")
    end)
    |> Enum.each(&run(&1, opts))
  end

  def run(file_path, opts) do
    with {:ok, app_definition} <- Forge.Namespace.Erlang.path_to_term(file_path),
         {:ok, converted} <- convert(app_definition, opts) do
      File.write(file_path, converted)
    end
  end

  @script_names ~w(start.script start_clean.script expert.rel)
  defp find_scripts(base_directory) do
    scripts_glob = "{" <> Enum.join(@script_names, ",") <> "}"

    [base_directory, "releases", "**", scripts_glob]
    |> Path.join()
    |> Path.wildcard()
  end

  defp convert(app_definition, opts) do
    converted = visit(app_definition, opts)
    erlang_terms = Forge.Namespace.Erlang.term_to_string(converted)

    script = """
    %% coding: utf-8
    #{erlang_terms}
    """

    {:ok, script}
  end

  # for .rel files
  defp visit({:release, release_vsn, erts_vsn, app_versions}, opts) do
    fixed_apps =
      Enum.map(app_versions, fn {app_name, version, start_type} ->
        {Forge.Namespace.Module.run(app_name, opts), version, start_type}
      end)

    {:release, release_vsn, erts_vsn, fixed_apps}
  end

  defp visit({:script, script_vsn, keys}, opts) do
    {:script, script_vsn, Enum.map(keys, &visit(&1, opts))}
  end

  defp visit({:primLoad, app_list}, opts) do
    {:primLoad, Enum.map(app_list, &Forge.Namespace.Module.run(&1, opts))}
  end

  defp visit({:path, paths}, opts) do
    {:path, Enum.map(paths, &Forge.Namespace.Path.run(&1, opts))}
  end

  defp visit({:apply, {:application, :load, load_apps}}, opts) do
    {:apply, {:application, :load, Enum.map(load_apps, &visit(&1, opts))}}
  end

  defp visit({:apply, {:application, :start_boot, apps_to_start}}, opts) do
    {:apply,
     {:application, :start_boot, Enum.map(apps_to_start, &Forge.Namespace.Module.run(&1, opts))}}
  end

  defp visit({:application, app_name, app_keys}, opts) do
    {:application, Forge.Namespace.Module.run(app_name, opts),
     Enum.map(app_keys, &visit(&1, opts))}
  end

  defp visit({:application, app_name}, opts) do
    {:application, Forge.Namespace.Module.run(app_name, opts)}
  end

  defp visit({:mod, {module_name, args}}, opts) do
    {:mod, {Forge.Namespace.Module.run(module_name, opts), Enum.map(args, &visit(&1, opts))}}
  end

  defp visit({:modules, module_list}, opts) do
    {:modules, Enum.map(module_list, &Forge.Namespace.Module.run(&1, opts))}
  end

  defp visit({:applications, app_names}, opts) do
    {:applications, Enum.map(app_names, &Forge.Namespace.Module.run(&1, opts))}
  end

  defp visit(key_value, _opts) do
    key_value
  end
end
