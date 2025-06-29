defmodule Engine.Plugin.Discovery do
  @moduledoc """
  Discovers any plugins in any loaded applications

  This module runs through the loaded applications and checks to see if any of them are expert plugins.
  If a plugin is found, the app is then registered with the plugin system.

  If we're running in a namespaced build, we must apply the same namespace to the plugin's modules, or it
  will be looking for structs like `Forge.Document`, and be passed in structs like `XPRelease.Document`,
  and the plugin will crash.
  """

  alias Engine.Module.Loader
  alias Engine.Plugin.Runner

  require Logger

  @namespaced_document_module [:Forge, :Document]
                              |> Module.concat()
                              |> Forge.Namespace.Module.apply()

  def run do
    for {app_name, _, _} <- :application.loaded_applications(),
        Runner.plugin_app?(app_name) do
      load_plugin_app(app_name)
    end

    Logger.info("Loaded #{inspect(Runner.enabled_plugins())}")
  end

  defp load_plugin_app(app_name) do
    with {:ok, modules} <- :application.get_key(app_name, :modules) do
      modules
      |> maybe_namespace()
      |> Runner.register_all()
    end
  end

  defp maybe_namespace(modules) when is_list(modules) do
    if namespaced?() do
      Enum.each(modules, fn module ->
        namespace_module(module)
        unload_module(module)
        Loader.ensure_loaded?(module)
      end)
    end

    modules
  end

  defp namespace_module(module) when is_atom(module) do
    module
    |> :code.which()
    |> List.to_string()
    |> Forge.Namespace.Transform.Beams.apply()
  end

  defp unload_module(module) do
    unless :code.delete(module) do
      :code.purge(module)
      :code.delete(module)
    end
  end

  def namespaced_doc do
    @namespaced_document_module
  end

  defp namespaced? do
    Loader.ensure_loaded?(@namespaced_document_module)
  end
end
