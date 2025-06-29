defmodule Expert.Project.Progress.Support do
  alias Expert.Project.Progress
  alias Forge.Project

  import Forge.EngineApi.Messages

  defmacro __using__(_) do
    quote do
      import unquote(__MODULE__), only: [with_progress: 3]
    end
  end

  def with_progress(project, label, func) when is_function(func, 0) do
    dest = Progress.name(project)

    try do
      send(dest, project_progress(label: label, stage: :begin))
      func.()
    after
      send(dest, project_progress(label: label, stage: :complete))
    end
  end

  def with_percentage_progress(%Project{} = project, label, max, func)
      when is_function(func, 1) do
    dest = Progress.name(project)

    report_progress = fn delta, message ->
      message =
        percent_progress(label: label, max: max, message: message, delta: delta, stage: :report)

      send(dest, message)
    end

    try do
      send(dest, percent_progress(label: label, max: max, stage: :begin))
      func.(report_progress)
    after
      send(dest, percent_progress(label: label, stage: :complete))
    end
  end
end
