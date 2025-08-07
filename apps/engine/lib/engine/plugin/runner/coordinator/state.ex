defmodule Engine.Plugin.Runner.Coordinator.State do
  @moduledoc false

  alias Engine.Plugin.Runner

  defstruct tasks: [], failures: %{}

  @max_plugin_errors 10

  require Logger

  def new do
    %__MODULE__{}
  end

  def run_all(%__MODULE__{} = state, subject, plugin_type, timeout) do
    tasks_to_plugin_modules =
      plugin_type
      |> Runner.plugins_of_type()
      |> Enum.map(&Runner.Supervisor.async(&1, subject))
      |> Map.new()

    await_results(state, tasks_to_plugin_modules, timeout)
  end

  def failure_count(%__MODULE__{} = state, plugin_module) do
    Map.get(state.failures, plugin_module, 0)
  end

  def remove_task(%__MODULE__{} = state, ref) do
    new_tasks = Enum.reject(state.tasks, &(&1.ref == ref))
    %__MODULE__{state | tasks: new_tasks}
  end

  defp await_results(%__MODULE__{} = state, tasks_to_plugin_modules, timeout) do
    raw_result =
      tasks_to_plugin_modules
      |> Map.keys()
      |> Task.yield_many(timeout)

    {successes, failed} =
      raw_result
      |> Enum.reduce({[], []}, fn
        {_task, {:ok, {:ok, results}}}, {successes, failures} when is_list(results) ->
          {[results | successes], failures}

        {task, {:ok, {:ok, _not_list}}}, {successes, failures} ->
          reason = "it did not return a list of results"
          failure = {:log, task, reason}
          {successes, [failure | failures]}

        {task, {:ok, reason}}, {successes, failures} ->
          failure = {:log, task, reason}
          {successes, [failure | failures]}

        {task, {:exit, reason}}, {successes, failures} ->
          failure = {:log, task, reason}
          {successes, [failure | failures]}

        {task, nil}, {successes, failures} ->
          failure = {:shutdown, task}
          {successes, [failure | failures]}
      end)

    new_state =
      Enum.reduce(failed, state, fn
        {:log, %Task{} = task, reason}, state ->
          plugin_module = Map.get(tasks_to_plugin_modules, task)
          Logger.error("Task #{plugin_module} failed because #{inspect(reason)}")
          mark_failed(state, plugin_module)

        {:shutdown, %Task{} = task}, state ->
          plugin_module = Map.get(tasks_to_plugin_modules, task)
          Logger.error("Task #{plugin_module} did not complete in #{timeout}ms ")
          Task.shutdown(task, :brutal_kill)
          mark_failed(state, plugin_module)
      end)

    results =
      successes
      |> Enum.reverse()
      |> List.flatten()

    {results, new_state}
  end

  defp mark_failed(%__MODULE__{} = state, plugin_module) do
    new_failures = Map.update(state.failures, plugin_module, 1, &(&1 + 1))
    maybe_shutdown(plugin_module, new_failures)
    %__MODULE__{state | failures: new_failures}
  end

  defp maybe_shutdown(plugin_module, failure_map) do
    case Map.get(failure_map, plugin_module, 0) do
      count when count >= @max_plugin_errors ->
        Runner.disable(plugin_module)

      _ ->
        :ok
    end
  end
end
