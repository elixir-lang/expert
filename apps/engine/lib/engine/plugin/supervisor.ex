defmodule Engine.Plugin.Runner.Supervisor do
  @moduledoc false

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {Task.Supervisor, :start_link, [[name: name()]]}
    }
  end

  @spec async(module(), term()) :: {Task.t(), module()}
  def async(plugin_module, subject) do
    task = Task.Supervisor.async_nolink(name(), plugin_module, :diagnose, [subject])
    {task, plugin_module}
  end

  defp name do
    Module.concat(__MODULE__, TaskSupervisor)
  end
end
