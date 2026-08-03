defmodule Engine.Mix do
  alias Forge.Internet
  alias Forge.Project

  require Logger

  def loaded? do
    not is_nil(Mix.Project.get())
  end

  def ensure_hex_and_rebar do
    if Internet.connected_to_internet?() do
      Mix.Task.run("local.hex", ~w(--force --if-missing))
      Mix.Task.run("local.rebar", ~w(--force --if-missing))
      :ok
    else
      Logger.warning("Could not connect to hex.pm, dependencies will not be fetched")
      :ok
    end
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
    with_lock(fn -> run_and_normalize(fn -> in_loaded_project(project, fun) end) end)
  end

  def deps_paths do
    :persistent_term.get({__MODULE__, :deps_paths}, %{})
  end

  # in_project/2 without the Engine.Mix lock and without changing the working
  # directory: a build holds that lock for a whole compile and formatting must
  # not wait on one, and callers pass project-relative paths in.
  # https://github.com/expert-lsp/expert/pull/804
  def with_project_config(%Project{kind: :mix} = project, fun) do
    run_and_normalize(fn -> with_pushed_project(project, fun) end)
  end

  def with_project_config(%Project{}, fun) do
    run_and_normalize(fn -> fun.(nil) end)
  end

  defp ensure_project_loaded(%Project{kind: :mix, project_module: nil} = project) do
    load_project_from_mix_exs(project)
  end

  defp ensure_project_loaded(%Project{} = project), do: project

  defp load_project_from_mix_exs(%Project{} = project) do
    build_path = Project.versioned_build_path(project)
    mix_exs_dir = project |> Project.mix_exs_path() |> Path.dirname()

    # Mix.Project.in_project/4 loads and caches the mix.exs module, but pushes
    # and pops it to do so, which is why it runs under the same StackMutation
    # lock as the push that follows it.
    Mix.Project.in_project(
      Project.atom_name(project),
      mix_exs_dir,
      [build_path: build_path],
      fn project_module ->
        Project.set_project_module(project, project_module)
      end
    )
  end

  defp in_loaded_project(%Project{} = project, fun) do
    File.cd!(Project.root_path(project), fn ->
      with_pushed_project(project, fn project_module ->
        record_deps_paths()
        fun.(project_module)
      end)
    end)
  end

  # Only the push and the pop take the StackMutation lock, never fun: it is a
  # whole compile under in_project/2, and formatter resolution is what #804 took
  # out from under a lock.
  defp with_pushed_project(%Project{} = project, fun) do
    {ownership, project_module} =
      Engine.with_lock(Engine.Mix.StackMutation, fn -> push_or_borrow(project) end)

    try do
      fun.(project_module)
    after
      Engine.with_lock(Engine.Mix.StackMutation, fn -> release_project(ownership) end)
    end
  end

  defp record_deps_paths do
    key = {__MODULE__, :deps_paths}
    deps_paths = Mix.Project.deps_paths()

    if :persistent_term.get(key, nil) != deps_paths do
      :persistent_term.put(key, deps_paths)
    end
  rescue
    ex ->
      Logger.warning("Could not record dependency paths: #{Exception.message(ex)}")
  end

  # Mix.Project.config/0 only reflects the project while it is on the project
  # stack, and Mix.Project.push/3 refuses a module that is already there, so a
  # project someone else pushed is borrowed and left for them to pop. Callers
  # hold the StackMutation lock.
  defp push_or_borrow(%Project{} = project) do
    if module = pushed_module(project) do
      {:borrowed, module}
    else
      project = ensure_project_loaded(project)
      push_project(project)
      {:pushed, project.project_module}
    end
  end

  defp release_project(:borrowed), do: :ok
  defp release_project(:pushed), do: Mix.Project.pop()

  defp pushed_module(%Project{} = project) do
    if Mix.Project.project_file() == Project.mix_exs_path(project) do
      Mix.Project.get()
    end
  end

  defp push_project(%Project{} = project) do
    Mix.ProjectStack.post_config(build_path: Project.versioned_build_path(project))

    try do
      Mix.Project.push(
        project.project_module,
        Project.mix_exs_path(project),
        Project.atom_name(project)
      )
    rescue
      ex ->
        # Only a successful push consumes the post_config; leaving it behind
        # would give the next project Mix pushes the engine's build path.
        Mix.ProjectStack.pop_post_config(:build_path)
        reraise ex, __STACKTRACE__
    end
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
