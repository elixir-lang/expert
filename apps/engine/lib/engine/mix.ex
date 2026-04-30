defmodule Engine.Mix do
  alias Forge.Project

  def loaded? do
    not is_nil(Mix.Project.get())
  end

  def in_project(fun) do
    case Engine.get_project() do
      %Project{} = project ->
        in_project(project, fun)

      _ ->
        {:error, :not_project_node}
    end
  end

  def in_project(%Project{kind: :bare}, fun) do
    run_and_normalize(fn -> fun.(nil) end)
  end

  def in_project(%Project{kind: :mix} = project, fun) do
    with_lock(fn ->
      run_and_normalize(fn ->
        project
        |> ensure_project_loaded()
        |> in_loaded_project(fun)
      end)
    end)
  end

  defp ensure_project_loaded(%Project{kind: :mix, project_module: nil} = project) do
    load_project_from_mix_exs(project)
  end

  defp ensure_project_loaded(%Project{} = project), do: project

  defp load_project_from_mix_exs(%Project{} = project) do
    build_path = Project.versioned_build_path(project)
    mix_exs_dir = project |> Project.mix_exs_path() |> Path.dirname()

    # Mix.Project.in_project/4 loads and caches the mix.exs module, but also
    # mutates ProjectStack internally. Keep that mutation locked and run the
    # caller callback later through in_loaded_project/2.
    Engine.with_lock(Engine.Mix.StackMutation, fn ->
      Mix.Project.in_project(
        Project.atom_name(project),
        mix_exs_dir,
        [prune_code_paths: false, build_path: build_path],
        fn project_module ->
          Project.set_project_module(project, project_module)
        end
      )
    end)
  end

  defp in_loaded_project(%Project{} = project, fun) do
    File.cd!(Project.root_path(project), fn ->
      # Push/pop mutate Mix.ProjectStack; the caller runs outside that lock so
      # other Mix helpers can safely mutate the stack while this project is active.
      push_project(project)

      try do
        fun.(project.project_module)
      after
        pop_project()
      end
    end)
  end

  defp push_project(%Project{} = project) do
    Engine.with_lock(Engine.Mix.StackMutation, fn ->
      Mix.ProjectStack.post_config(
        prune_code_paths: false,
        build_path: Project.versioned_build_path(project)
      )

      Mix.Project.push(
        project.project_module,
        Project.mix_exs_path(project),
        Project.atom_name(project)
      )
    end)
  end

  defp pop_project do
    Engine.with_lock(Engine.Mix.StackMutation, fn -> Mix.Project.pop() end)
  end

  defp run_and_normalize(fun) do
    fun.()
    |> normalize_result()
  rescue
    ex ->
      exception_error(ex, __STACKTRACE__)
  end

  defp normalize_result(result) do
    case result do
      error when is_tuple(error) and elem(error, 0) == :error ->
        error

      ok when is_tuple(ok) and elem(ok, 0) == :ok ->
        ok

      other ->
        {:ok, other}
    end
  end

  defp exception_error(exception, stacktrace) do
    blamed = Exception.blame(:error, exception, stacktrace)
    {:error, {:exception, blamed, stacktrace}}
  end

  defp with_lock(fun) do
    Engine.with_lock(__MODULE__, fun)
  end
end
