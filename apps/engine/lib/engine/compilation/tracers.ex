defmodule Engine.Compilation.Tracers do
  @moduledoc false

  alias Engine.Compilation.DependencyTracer
  alias Engine.Compilation.ProjectTracer
  alias Forge.Project

  @expert_tracers [ProjectTracer, DependencyTracer]

  def with(tracers, fun) when is_list(tracers) and is_function(fun, 0) do
    __MODULE__.with(tracers, [], fun)
  end

  def with(tracers, opts, fun) when is_list(tracers) and is_list(opts) and is_function(fun, 0) do
    previous = Code.get_compiler_option(:tracers)
    set(tracers, List.wrap(previous))

    try do
      maybe_with_project_scope(tracers, opts, fun)
    after
      Code.put_compiler_option(:tracers, previous)
    end
  end

  def with_project(%Project{} = project, tracers, fun)
      when is_list(tracers) and is_function(fun, 0) do
    with_project(project, tracers, [], fun)
  end

  def with_project(%Project{} = project, tracers, opts, fun)
      when is_list(tracers) and is_list(opts) and is_function(fun, 0) do
    __MODULE__.with(tracers, Keyword.put(opts, :project, project), fun)
  end

  defp maybe_with_project_scope(tracers, opts, fun) do
    if ProjectTracer in tracers do
      with_project_scope(opts, fun)
    else
      fun.()
    end
  end

  defp with_project_scope(opts, fun) do
    case Keyword.get(opts, :project) || Engine.get_project() do
      %Project{} = project -> ProjectTracer.with_project(project, opts, fun)
      _ -> fun.()
    end
  end

  defp set(tracers, previous) when is_list(tracers) and is_list(previous) do
    Code.put_compiler_option(:tracers, Enum.uniq(tracers ++ (previous -- @expert_tracers)))
  end
end
