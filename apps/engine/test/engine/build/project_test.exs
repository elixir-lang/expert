defmodule Engine.Build.ProjectTest do
  use ExUnit.Case, async: false
  use Patch

  alias Engine.Build
  alias Engine.Progress
  alias Forge.Document
  alias Forge.Internet
  alias Forge.Project

  setup do
    start_supervised!(Engine.Dispatch)
    start_supervised!(Build.CaptureServer)
    start_supervised!(Engine.ModuleMappings)

    patch(Internet, :connected_to_internet?, false)

    patch(Progress, :with_progress, fn _title, work ->
      {:done, result} = work.(Progress.noop_token())
      result
    end)

    previous_env = Mix.env()

    on_exit(fn ->
      Mix.env(previous_env)
      clear_mix_state()
    end)

    :ok
  end

  @tag :tmp_dir
  test "initial build loads development and test dependencies", %{tmp_dir: tmp_dir} do
    project = dependency_project!(tmp_dir)
    Engine.set_project(project)
    Mix.env(:test)

    assert {:ok, project_diagnostics} = Build.Project.compile(project, true)
    refute missing_module_diagnostic?(project_diagnostics)

    assert {:module, DevOnlyDependency} = Code.ensure_loaded(DevOnlyDependency)
    assert {:module, TestOnlyDependency} = Code.ensure_loaded(TestOnlyDependency)
    assert {:module, SharedDependency} = Code.ensure_loaded(SharedDependency)
    assert {:module, TestSupportModule} = Code.ensure_loaded(TestSupportModule)
    assert {:module, DependencyProject} = Code.ensure_loaded(DependencyProject)
    assert DependencyProject.dependencies_available?()

    script =
      Document.new(
        Path.join(Project.root_path(project), "script.exs"),
        """
        DevOnlyDependency.available?()
        TestOnlyDependency.available?()
        SharedDependency.available?()
        TestSupportModule.available?()
        """,
        0
      )

    assert {:ok, script_diagnostics} = Build.Document.compile(script)
    refute missing_module_diagnostic?(script_diagnostics)

    assert Mix.env() == :test

    assert {:ok, deps_apps} =
             Engine.Mix.in_project(project, fn _ ->
               Mix.Dep.clear_cached()
               Mix.Project.clear_deps_cache()
               Mix.Project.deps_apps()
             end)

    assert :test_only_dependency in deps_apps
    assert :shared_dependency in deps_apps
    refute :dev_only_dependency in deps_apps

    assert File.read!(Path.join(tmp_dir, "shared_dependency/compile_count")) == "compiled\n"

    assert {:ok, rebuild_diagnostics} = Build.Project.compile(project, false)
    refute missing_module_diagnostic?(rebuild_diagnostics)
    assert Mix.env() == :test
  end

  @tag :tmp_dir
  test "failed development dependency preparation restores the test environment", %{
    tmp_dir: tmp_dir
  } do
    project = broken_dependency_project!(tmp_dir)
    Engine.set_project(project)
    Mix.env(:test)

    assert {:error, {:exception, _blamed, _stacktrace}} = Build.Project.compile(project, true)
    assert Mix.env() == :test

    assert {:ok, deps_apps} =
             Engine.Mix.in_project(project, fn _ ->
               Mix.Dep.clear_cached()
               Mix.Project.clear_deps_cache()
               Mix.Project.deps_apps()
             end)

    refute :broken_dev_dependency in deps_apps
  end

  defp dependency_project!(tmp_dir) do
    write_dependency!(tmp_dir, :dev_only_dependency, DevOnlyDependency)
    write_dependency!(tmp_dir, :test_only_dependency, TestOnlyDependency)
    write_dependency!(tmp_dir, :shared_dependency, SharedDependency, count_compiles?: true)

    root = Path.join(tmp_dir, "dependency_project")

    write_file!(Path.join(root, "mix.exs"), """
    defmodule DependencyProject.MixProject do
      use Mix.Project

      def project do
        [
          app: :dependency_project,
          version: "0.1.0",
          elixirc_paths: elixirc_paths(Mix.env()),
          deps: deps()
        ]
      end

      defp elixirc_paths(:test), do: ["lib", "test/support"]
      defp elixirc_paths(_), do: ["lib"]

      defp deps do
        [
          {:dev_only_dependency, path: "../dev_only_dependency", only: :dev},
          {:test_only_dependency, path: "../test_only_dependency", only: :test},
          {:shared_dependency, path: "../shared_dependency"}
        ]
      end
    end
    """)

    write_file!(Path.join(root, "lib/dependency_project.ex"), """
    defmodule DependencyProject do
      def dependencies_available? do
        DevOnlyDependency.available?() and TestOnlyDependency.available?() and
          SharedDependency.available?()
      end
    end
    """)

    write_file!(Path.join(root, "test/support/test_support_module.ex"), """
    defmodule TestSupportModule do
      def available?, do: true
    end
    """)

    project = Project.new(Document.Path.to_uri(root))
    :ok = Project.ensure_workspace(project)
    project
  end

  defp broken_dependency_project!(tmp_dir) do
    write_dependency!(tmp_dir, :broken_dev_dependency, BrokenDevDependency,
      source: "defmodule BrokenDevDependency do"
    )

    root = Path.join(tmp_dir, "broken_dependency_project")

    write_file!(Path.join(root, "mix.exs"), """
    defmodule BrokenDependencyProject.MixProject do
      use Mix.Project

      def project do
        [
          app: :broken_dependency_project,
          version: "0.1.0",
          deps: [{:broken_dev_dependency, path: "../broken_dev_dependency", only: :dev}]
        ]
      end
    end
    """)

    write_file!(Path.join(root, "lib/broken_dependency_project.ex"), """
    defmodule BrokenDependencyProject do
    end
    """)

    project = Project.new(Document.Path.to_uri(root))
    :ok = Project.ensure_workspace(project)
    project
  end

  defp write_dependency!(tmp_dir, app, module, opts \\ []) do
    root = Path.join(tmp_dir, Atom.to_string(app))

    write_file!(Path.join(root, "mix.exs"), """
    defmodule #{inspect(module)}.MixProject do
      use Mix.Project

      def project do
        [app: #{inspect(app)}, version: "0.1.0"]
      end
    end
    """)

    source =
      Keyword.get_lazy(opts, :source, fn ->
        compile_counter =
          if opts[:count_compiles?] do
            "File.write!(Path.expand(\"../compile_count\", __DIR__), \"compiled\\n\", [:append])"
          else
            ""
          end

        """
        defmodule #{inspect(module)} do
          #{compile_counter}
          def available?, do: true
        end
        """
      end)

    write_file!(Path.join(root, "lib/#{app}.ex"), source)
  end

  defp write_file!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp missing_module_diagnostic?(diagnostics) do
    Enum.any?(diagnostics, fn diagnostic ->
      String.contains?(diagnostic.message, "is not loaded") and
        String.contains?(diagnostic.message, "found")
    end)
  end

  defp clear_mix_state do
    Mix.Task.clear()
    Mix.Dep.clear_cached()
    Mix.Project.clear_deps_cache()
  end
end
