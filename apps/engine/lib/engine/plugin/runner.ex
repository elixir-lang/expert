defmodule Engine.Plugin.Runner do
  @moduledoc false

  alias Engine.Module.Loader
  alias Engine.Plugin.Runner
  alias Forge.Document
  alias Forge.Project

  require Logger

  @project_level_plugin_timeout_ms :timer.seconds(3)
  @file_level_plugin_timeout_ms 50

  @doc false
  def clear_config do
    :persistent_term.erase(__MODULE__)
  end

  @doc false
  def plugin_module?(module) when is_atom(module) do
    function_exported?(module, :__expert_plugin__, 0)
  end

  @doc false
  def plugin_app?(app_name) do
    Application.get_env(app_name, expert_prefixed_atom("plugin"), false)
  end

  @doc false
  def enabled_plugins do
    config()
    |> Map.keys()
    |> Enum.map(& &1.name())
  end

  @doc false
  def diagnose(%Project{} = project, on_complete) do
    Runner.Coordinator.run_all(
      project,
      :diagnostic,
      on_complete,
      @project_level_plugin_timeout_ms
    )
  end

  @doc false
  def diagnose(%Document{} = document, on_complete) do
    Runner.Coordinator.run_all(document, :diagnostic, on_complete, @file_level_plugin_timeout_ms)
  end

  @doc false
  def disable(plugin_module) when is_atom(plugin_module) do
    Logger.error("Disabling Plugin #{plugin_module.name()} due to errors")

    config()
    |> Map.delete(plugin_module)
    |> write_config()
  end

  @doc false
  def register_all(modules) when is_list(modules) do
    for module <- modules,
        Loader.ensure_loaded?(module),
        plugin_module?(module) do
      register(module)
    end
  end

  @doc false
  def register(plugin_module) when is_atom(plugin_module) do
    current_plugins = config()

    with {:ok, plugin_type} <- fetch_plugin_type(plugin_module),
         :error <- Map.fetch(current_plugins, plugin_module),
         :ok <- plugin_module.init() do
      current_plugins
      |> Map.put(plugin_module, plugin_type)
      |> write_config()

      :ok
    else
      error ->
        Logger.warning(
          "Could not register plugin #{inspect(plugin_module)} because #{inspect(error)}"
        )

        :error
    end
  end

  @doc false
  def plugins_of_type(plugin_type) do
    for {plugin_module, ^plugin_type} <- config() do
      plugin_module
    end
  end

  defp config do
    :persistent_term.get(__MODULE__, %{})
  end

  defp write_config(config) do
    :persistent_term.put(__MODULE__, config)
  end

  defp fetch_plugin_type(module) do
    if function_exported?(module, :__plugin_type__, 0) do
      {:ok, module.__plugin_type__()}
    else
      :error
    end
  end

  defp expert_prefixed_atom(suffix) do
    ("expert_" <> suffix)
    |> String.to_atom()
  end
end
