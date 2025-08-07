defmodule Engine.Mix do
  alias Forge.Project

  def in_project(fun) do
    if Engine.project_node?() do
      in_project(Engine.get_project(), fun)
    else
      {:error, :not_project_node}
    end
  end

  def in_project(%Project{} = project, fun) do
    # Locking on the build make sure we don't get a conflict on the mix.exs being
    # already defined

    old_cwd = File.cwd!()

    with_lock(fn ->
      try do
        Mix.ProjectStack.post_config(prune_code_paths: false)

        build_path = Project.versioned_build_path(project)
        project_root = Project.root_path(project)

        project
        |> Project.atom_name()
        |> Mix.Project.in_project(project_root, [build_path: build_path], fun)
      rescue
        ex ->
          blamed = Exception.blame(:error, ex, __STACKTRACE__)
          {:error, {:exception, blamed, __STACKTRACE__}}
      else
        result ->
          case result do
            error when is_tuple(error) and elem(error, 0) == :error ->
              error

            ok when is_tuple(ok) and elem(ok, 0) == :ok ->
              ok

            other ->
              {:ok, other}
          end
      after
        File.cd!(old_cwd)
      end
    end)
  end

  defp with_lock(fun) do
    Engine.with_lock(__MODULE__, fun)
  end
end
