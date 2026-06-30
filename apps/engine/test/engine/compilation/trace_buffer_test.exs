defmodule Engine.Compilation.TraceBufferTest do
  use ExUnit.Case, async: false
  use Forge.Test.EventualAssertions
  use Patch

  alias Engine.Build
  alias Engine.Compilation.DependencyTracer
  alias Engine.Compilation.ProjectTracer
  alias Engine.Compilation.TraceBuffer
  alias Engine.Compilation.Tracers
  alias Engine.Search.Indexer.Manifest
  alias Engine.Search.Indexer.ManifestStore
  alias Engine.Search.Indexer.Paths
  alias Engine.Test.SearchBackend
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Formats
  alias Forge.Project
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Indexer.Source.Block

  @moduletag :tmp_dir
  @dependency_compile_partition_env "MIX_OS_DEPS_COMPILE_PARTITION_COUNT"

  setup %{tmp_dir: tmp_dir} do
    project = project(tmp_dir)

    Engine.set_project(project)
    SearchBackend.set_entries([])

    start_supervised!(Engine.ApplicationCache)
    start_supervised!(TraceBuffer)
    start_supervised!(Engine.Dispatch)

    patch(Engine.Api.Proxy, :broadcast, fn _message -> :ok end)

    patch(Engine.ManagerApi, :search_store_commit_traces, fn _project, trace_updates ->
      SearchBackend.commit_traces(trace_updates)
    end)

    compiler_options = Code.compiler_options()

    Code.compiler_options(
      debug_info: true,
      parser_options: [columns: true, token_metadata: true]
    )

    on_exit(fn -> Code.compiler_options(compiler_options) end)

    {:ok, project: project}
  end

  describe "trace buffer state" do
    test "distinguishes traced empty files from untraced files", %{
      project: project,
      tmp_dir: tmp_dir
    } do
      traced_path = Path.join(tmp_dir, "traced_empty.ex")
      untraced_path = Path.join(tmp_dir, "untraced.ex")

      File.write!(traced_path, "")
      File.write!(untraced_path, "")

      refute TraceBuffer.traced?(untraced_path)

      TraceBuffer.clear(traced_path)

      assert TraceBuffer.traced?(traced_path)
      assert :ok = TraceBuffer.commit_path(project, traced_path)
      refute TraceBuffer.traced?(traced_path)
    end

    test "canonicalizes paths before emitting entries and manifest data", %{
      project: project,
      tmp_dir: tmp_dir
    } do
      source_path = native_join([tmp_dir, "lib", "canonical_trace.ex"])
      beam_path = native_join([tmp_dir, "ebin", "Elixir.CanonicalTrace.beam"])
      module = Module.concat(__MODULE__, :CanonicalTrace)

      File.mkdir_p!(Path.dirname(source_path))
      File.mkdir_p!(Path.dirname(beam_path))
      File.write!(source_path, "defmodule #{inspect(module)} do end")
      File.write!(beam_path, "beam")

      relative_source_path = Path.relative_to(source_path, tmp_dir)
      relative_beam_path = Path.relative_to(beam_path, tmp_dir)

      File.cd!(tmp_dir, fn ->
        TraceBuffer.clear(relative_source_path)

        TraceBuffer.add_definitions(relative_source_path, module, [
          module_definition(relative_source_path, module)
        ])

        TraceBuffer.add_beam_path(relative_source_path, relative_beam_path)
      end)

      assert TraceBuffer.traced?(source_path)

      entries = SearchBackend.entries()
      assert Enum.all?(entries, &(&1.path == source_path))

      assert :ok = TraceBuffer.commit_path(project, source_path)
      assert {:ok, manifest} = ManifestStore.load(project)

      assert [%{kind: :beam, input_path: ^beam_path, output_path: ^source_path}] =
               Manifest.entries(manifest)
    end

    test "does not commit failed trace writes to the search store", %{tmp_dir: tmp_dir} do
      module = Module.concat(__MODULE__, :FailedTraceMutation)
      source_path = Path.join(tmp_dir, "failed_trace_mutation.ex")
      old_definition = module_definition(source_path, module)
      old_reference = reference(source_path, Formats.mfa(Enum, :map, 2))

      SearchBackend.set_entries([old_definition, old_reference])

      File.write!(source_path, """
      defmodule #{inspect(module)} do
        @after_compile __MODULE__
        def __after_compile__(_env, _bytecode), do: raise "boom"
        def value(values), do: Enum.map(values, & &1)
      end
      """)

      assert_raise RuntimeError, ~r/boom/, fn ->
        compile_project_file(tmp_dir, source_path)
      end

      TraceBuffer.discard(source_path)

      assert [^old_definition, ^old_reference] = SearchBackend.entries()
    end

    test "does not treat unsaved trace output as a current disk source manifest", %{
      project: project,
      tmp_dir: tmp_dir
    } do
      saved_module = Module.concat(__MODULE__, :SavedDiskModule)
      unsaved_module = Module.concat(__MODULE__, :UnsavedBufferModule)
      source_path = Path.join(tmp_dir, "unsaved_buffer_trace.ex")

      File.write!(source_path, "defmodule #{inspect(saved_module)} do end\n")

      TraceBuffer.clear(source_path)

      TraceBuffer.add_definitions(source_path, unsaved_module, [
        module_definition(source_path, unsaved_module)
      ])

      assert :ok = TraceBuffer.commit_path(project, source_path)

      patch_progress()

      assert {:ok, updated_entries, paths_to_clear, manifest} =
               Engine.Search.Indexer.update_index(project, SearchBackend.path_to_ids())

      assert {:ok, _deleted_ids} =
               SearchBackend.apply_index_update(project, updated_entries, paths_to_clear)

      assert :ok = Engine.Search.Indexer.commit_manifest(project, manifest)

      entries = SearchBackend.entries()

      refute Enum.any?(entries, &(&1.subject == unsaved_module))
      assert Enum.any?(entries, &(&1.subject == saved_module))
    end

    test "clears attempted paths after a failed commit", %{project: project, tmp_dir: tmp_dir} do
      module = Module.concat(__MODULE__, :FailedCommitTrace)
      source_path = Path.join(tmp_dir, "failed_commit_trace.ex")

      File.write!(source_path, "defmodule #{inspect(module)} do end\n")

      TraceBuffer.clear(source_path)
      TraceBuffer.add_definitions(source_path, module, [module_definition(source_path, module)])

      patch(ManifestStore, :update, fn ^project, _update_fun ->
        {:error, :manifest_failed}
      end)

      assert {:error, :manifest_failed} = TraceBuffer.commit_path(project, source_path)
      refute TraceBuffer.traced?(source_path)
    end

    test "keeps attempted paths after a failed search commit", %{
      project: project,
      tmp_dir: tmp_dir
    } do
      module = Module.concat(__MODULE__, :FailedSearchCommitTrace)
      source_path = Path.join(tmp_dir, "failed_search_commit_trace.ex")

      File.write!(source_path, "defmodule #{inspect(module)} do end\n")

      TraceBuffer.clear(source_path)
      TraceBuffer.add_definitions(source_path, module, [module_definition(source_path, module)])

      patch(Engine.ManagerApi, :search_store_commit_traces, fn ^project, _trace_updates ->
        {:error, :not_started}
      end)

      assert {:error, :not_started} = TraceBuffer.commit_path(project, source_path)
      assert TraceBuffer.traced?(source_path)
    end

    test "trace buffer manifest commit does not discover every project path", %{
      project: project,
      tmp_dir: tmp_dir
    } do
      source_path = native_join([tmp_dir, "manifest_without_project_discovery.ex"])
      File.write!(source_path, "defmodule ManifestWithoutProjectDiscovery do end\n")

      patch(Paths, :for_project, fn ^project -> raise "should not discover all project paths" end)

      TraceBuffer.clear(source_path)

      assert :ok = TraceBuffer.commit_path(project, source_path)
      assert {:ok, manifest} = ManifestStore.load(project)

      assert [%{kind: :source, input_path: ^source_path}] = Manifest.entries(manifest)
    end

    test "removes previously traced modules after trace buffer restart", %{
      project: project,
      tmp_dir: tmp_dir
    } do
      old_module = Module.concat(__MODULE__, :RestartOldModule)
      new_module = Module.concat(__MODULE__, :RestartNewModule)
      source_path = Path.join(tmp_dir, "restart_trace.ex")

      File.write!(source_path, "defmodule #{inspect(old_module)} do end\n")

      TraceBuffer.clear(source_path)

      TraceBuffer.add_definitions(source_path, old_module, [
        module_definition(source_path, old_module)
      ])

      assert :ok = TraceBuffer.commit_path(project, source_path)

      stop_supervised!(TraceBuffer)
      start_supervised!(TraceBuffer)

      File.write!(source_path, "defmodule #{inspect(new_module)} do end\n")

      TraceBuffer.clear(source_path)

      TraceBuffer.add_definitions(source_path, new_module, [
        module_definition(source_path, new_module)
      ])

      assert :ok = TraceBuffer.commit_path(project, source_path)

      entries = SearchBackend.entries()

      refute Enum.any?(entries, &(&1.subject == old_module))
      assert Enum.any?(entries, &(&1.subject == new_module))
    end
  end

  describe "project tracer" do
    test "buffers compiler traced definitions and references", %{
      project: project,
      tmp_dir: tmp_dir
    } do
      module = Module.concat(__MODULE__, :"Sample#{System.unique_integer([:positive])}")
      path = Path.join(tmp_dir, "sample.ex")

      File.write!(path, """
      defmodule #{inspect(module)} do
        def public(values), do: private(values)
        defp private(values), do: Enum.map(values, & &1)
      end
      """)

      compile_project_file(tmp_dir, path)
      assert :ok = TraceBuffer.commit_project(project)

      public = Formats.mfa(module, :public, 1)
      private = Formats.mfa(module, :private, 1)
      enum_map = Formats.mfa(Enum, :map, 2)

      assert_eventually(
        Enum.any?(
          SearchBackend.entries(),
          &(&1.subject == module and &1.type == :module and
              &1.subtype == :definition)
        ),
        500
      )

      entries = SearchBackend.entries()

      assert Enum.any?(
               entries,
               &(&1.subject == public and &1.type == {:function, :public} and
                   &1.subtype == :definition)
             )

      assert Enum.any?(
               entries,
               &(&1.subject == private and &1.type == {:function, :private} and
                   &1.subtype == :definition)
             )

      assert Enum.any?(
               entries,
               &(&1.subject == private and &1.type == {:function, :usage} and
                   &1.subtype == :reference)
             )

      assert Enum.any?(
               entries,
               &(&1.subject == enum_map and &1.type == {:function, :usage} and
                   &1.subtype == :reference)
             )
    end

    test "stores source-backed ranges for compiler traced references", %{
      project: project,
      tmp_dir: tmp_dir
    } do
      module = Module.concat(__MODULE__, :TracedReferenceRange)
      path = Path.join(tmp_dir, "traced_reference_range.ex")

      source = """
      defmodule #{inspect(module)} do
        def value do
          Forge.Identifier.next_global!()
        end
      end
      """

      File.write!(path, source)

      compile_project_file(tmp_dir, path)
      assert :ok = TraceBuffer.commit_project(project)

      subject = Formats.mfa(Forge.Identifier, :next_global!, 0)

      assert_eventually(%Entry{} = reference_entry(subject), 500)

      entry = reference_entry(subject)
      assert entry.range.start.line == 3
      assert entry.range.start.character == source_column(source, 3, "next_global!")

      assert entry.range.end.character ==
               entry.range.start.character + String.length("next_global!")

      assert entry.range.start.document_line_count > 0
    end

    test "uses scoped dirty document when tracing reference ranges", %{
      project: project,
      tmp_dir: tmp_dir
    } do
      module = Module.concat(__MODULE__, :DirtyReferenceRange)
      path = Path.join(tmp_dir, "dirty_reference_range.ex")

      File.write!(path, "defmodule #{inspect(module)} do\n  def value, do: :disk\nend\n")

      source = """
      defmodule #{inspect(module)} do
        def value do
          :memory
          Forge.Identifier.next_global!()
        end
      end
      """

      document = Document.new(path, source, 2)
      Engine.set_project(project)

      Tracers.with_project(project, [ProjectTracer], fn ->
        Code.compile_string(source, path)
      end)

      assert :ok = TraceBuffer.commit_path(project, path, source_document: document)

      subject = Formats.mfa(Forge.Identifier, :next_global!, 0)

      assert_eventually(%Entry{} = reference_entry(subject), 500)

      entry = reference_entry(subject)
      assert entry.range.start.line == 4
      assert entry.range.start.character == source_column(source, 4, "next_global!")
    end

    test "ignores script files", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "sample.exs")
      module = Module.concat(__MODULE__, :"Script#{System.unique_integer([:positive])}")

      compile_project_string(
        tmp_dir,
        "defmodule #{inspect(module)} do\n  def value, do: :ok\nend\n",
        path
      )

      refute TraceBuffer.traced?(path)
      refute Enum.any?(SearchBackend.entries(), &(&1.path == path))
    end

    test "reports file progress without buffering non-project files", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "unscoped_progress.ex")
      module = Module.concat(__MODULE__, :"UnscopedProgress#{System.unique_integer([:positive])}")

      File.write!(path, "defmodule #{inspect(module)} do\n  def value, do: :ok\nend\n")

      other_project = tmp_dir |> Path.join("other") |> project()
      Engine.set_project(other_project)

      assert_progress_reported(fn ->
        Tracers.with([ProjectTracer], fn -> Code.compile_file(path) end)
      end)

      refute TraceBuffer.traced?(path)
      refute Enum.any?(SearchBackend.entries(), &(&1.path == path))
    end

    test "restores scoped project tracing after compile", %{tmp_dir: tmp_dir} do
      project_path = native_join([tmp_dir, "project"])
      File.mkdir_p!(project_path)

      project_file = native_join([project_path, "project_module.ex"])
      ambient_file = native_join([project_path, "ambient_module.ex"])

      project_module =
        Module.concat(__MODULE__, :"ScopedProject#{System.unique_integer([:positive])}")

      ambient_module =
        Module.concat(__MODULE__, :"AmbientProject#{System.unique_integer([:positive])}")

      File.write!(
        project_file,
        "defmodule #{inspect(project_module)} do\n  def value, do: :ok\nend\n"
      )

      File.write!(
        ambient_file,
        "defmodule #{inspect(ambient_module)} do\n  def value, do: :ok\nend\n"
      )

      project = project(project_path)
      Engine.set_project(project)

      Tracers.with([ProjectTracer], fn -> Code.compile_file(project_file) end)
      Code.compile_file(ambient_file)
      assert :ok = TraceBuffer.commit_project(project)

      entries = SearchBackend.entries()

      assert Enum.any?(entries, &(&1.path == project_file and &1.subject == project_module))
      refute Enum.any?(entries, &(&1.path == ambient_file and &1.subject == ambient_module))
    end

    test "records the actual Elixir BEAM path in the manifest", %{tmp_dir: tmp_dir} do
      module = Module.concat(__MODULE__, :"ManifestBeamPath#{System.unique_integer([:positive])}")

      project_module =
        Module.concat(__MODULE__, :"ManifestMixProject#{System.unique_integer([:positive])}")

      app = :"trace_buffer_manifest_#{System.unique_integer([:positive])}"

      write_mix_project!(tmp_dir, project_module, app)
      source_path = native_join([tmp_dir, "lib", "manifest_beam_path.ex"])
      File.mkdir_p!(Path.dirname(source_path))

      File.write!(source_path, """
      defmodule #{inspect(module)} do
        def value, do: :ok
      end
      """)

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.new()
      Engine.set_project(project)

      {:ok, expected_beam_path} =
        Engine.Mix.in_project(project, fn _ ->
          Mix.Task.clear()
          expected = native_join([Mix.Project.compile_path(), "#{Atom.to_string(module)}.beam"])

          Tracers.with([ProjectTracer], fn ->
            Mix.Task.run(:compile, ["--force"])
          end)

          expected
        end)

      assert :ok = TraceBuffer.commit_project(project)
      assert {:ok, manifest} = ManifestStore.load(project)

      assert [%{input_path: ^expected_beam_path}] =
               manifest
               |> Manifest.entries()
               |> Enum.filter(&(&1.source_path == source_path))
    end
  end

  describe "dependency tracer" do
    test "buffers public definitions without references", %{project: project, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dependency_progress.ex")

      module =
        Module.concat(__MODULE__, :"DependencyProgress#{System.unique_integer([:positive])}")

      File.write!(
        path,
        "defmodule #{inspect(module)} do\n  def value, do: private()\n  defp private, do: Enum.map([], & &1)\nend\n"
      )

      Tracers.with([DependencyTracer], fn ->
        assert_progress_reported(fn -> Code.compile_file(path) end)
      end)

      assert :ok = TraceBuffer.commit_project(project)

      entries = SearchBackend.entries()

      assert Enum.any?(
               entries,
               &(&1.subject == module and &1.type == :module and &1.subtype == :definition)
             )

      assert Enum.any?(
               entries,
               &(&1.subject == Formats.mfa(module, :value, 0) and
                   &1.type == {:function, :public} and &1.subtype == :definition)
             )

      refute Enum.any?(entries, &(&1.subject == Formats.mfa(module, :private, 0)))
      refute Enum.any?(entries, &(&1.subtype == :reference))
    end

    test "records the actual BEAM path in the manifest", %{tmp_dir: tmp_dir} do
      module =
        Module.concat(
          __MODULE__,
          :"DependencyManifestBeamPath#{System.unique_integer([:positive])}"
        )

      project_module =
        Module.concat(
          __MODULE__,
          :"DependencyManifestMixProject#{System.unique_integer([:positive])}"
        )

      app = :"dependency_trace_buffer_manifest_#{System.unique_integer([:positive])}"

      write_mix_project!(tmp_dir, project_module, app)
      source_path = native_join([tmp_dir, "lib", "dependency_manifest_beam_path.ex"])
      File.mkdir_p!(Path.dirname(source_path))

      File.write!(source_path, """
      defmodule #{inspect(module)} do
        def value, do: :ok
      end
      """)

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.new()

      {:ok, expected_beam_path} =
        Engine.Mix.in_project(project, fn _ ->
          Mix.Task.clear()
          expected = native_join([Mix.Project.compile_path(), "#{Atom.to_string(module)}.beam"])

          Tracers.with([DependencyTracer], fn ->
            Mix.Task.run(:compile, ["--force"])
          end)

          expected
        end)

      assert :ok = TraceBuffer.commit_project(project)
      assert {:ok, manifest} = ManifestStore.load(project)

      assert [%{input_path: ^expected_beam_path}] =
               manifest
               |> Manifest.entries()
               |> Enum.filter(&(&1.source_path == source_path))
    end

    test "deps.loadpaths traces dependencies from a clean project stack", %{tmp_dir: tmp_dir} do
      %{dep_module: dep_module, project: project, project_module: project_module} =
        path_dependency_project!(tmp_dir)

      Engine.set_project(project)

      assert {:ok, ^project_module} = Engine.Mix.in_project(project, fn module -> module end)
      project = Project.set_project_module(project, project_module)

      Tracers.with([DependencyTracer], fn ->
        Engine.Mix.in_project_with_clean_stack(project, fn _ ->
          Mix.Task.clear()
          Mix.Dep.clear_cached()
          Mix.Project.clear_deps_cache()
          Mix.Task.rerun("deps.loadpaths")
        end)
      end)

      assert :ok = TraceBuffer.commit_project(project)

      entries = SearchBackend.entries()

      assert Enum.any?(entries, &(&1.subject == dep_module and &1.subtype == :definition))
    end

    test "normal project compiles trace dependencies before project compilation", %{
      tmp_dir: tmp_dir
    } do
      %{
        dep_module: dep_module,
        project: project,
        project_module: project_module,
        source_path: source_path
      } = path_dependency_project!(tmp_dir)

      Engine.set_project(project)

      assert {:ok, ^project_module} = Engine.Mix.in_project(project, fn module -> module end)
      project = Project.set_project_module(project, project_module)

      patch_progress()
      patch(Engine.Mix, :ensure_hex_and_rebar, fn -> :ok end)

      assert {:ok, []} = Engine.Build.Project.compile(project, false)

      assert :ok = TraceBuffer.commit_project(project)
      entries = SearchBackend.entries()
      assert {:ok, manifest} = ManifestStore.load(project)
      manifest_entries = Manifest.entries(manifest)

      assert Enum.any?(entries, &(&1.subject == dep_module and &1.subtype == :definition))

      assert Enum.any?(
               manifest_entries,
               &(&1.kind == :beam and &1.source_path == source_path)
             )
    end

    test "dependency tracing serializes OS dependency compile partitions", %{tmp_dir: tmp_dir} do
      unique = System.unique_integer([:positive])
      project_module = Module.concat(__MODULE__, :"PartitionMixProject#{unique}")
      app = :"partition_trace_#{unique}"
      dep_apps = [:"partition_dep_a_#{unique}", :"partition_dep_b_#{unique}"]

      write_partition_project!(tmp_dir, project_module, app, dep_apps)

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.new()
      Engine.set_project(project)

      assert {:ok, ^project_module} = Engine.Mix.in_project(project, fn module -> module end)
      project = Project.set_project_module(project, project_module)

      original_partition_count = System.fetch_env(@dependency_compile_partition_env)
      System.put_env(@dependency_compile_partition_env, "4")

      on_exit(fn -> restore_env(@dependency_compile_partition_env, original_partition_count) end)

      patch_progress()
      patch(Engine.Mix, :ensure_hex_and_rebar, fn -> :ok end)

      assert {:ok, []} = Engine.Build.Project.compile(project, false)

      for dep_app <- dep_apps do
        assert "1" =
                 [tmp_dir, "deps", Atom.to_string(dep_app), "partition_count.txt"]
                 |> Path.join()
                 |> File.read!()
      end

      assert System.get_env(@dependency_compile_partition_env) == "4"
    end
  end

  describe "project compilation" do
    test "reports actual compile duration", %{tmp_dir: tmp_dir} do
      module =
        Module.concat(__MODULE__, :"TimedProjectCompile#{System.unique_integer([:positive])}")

      project_module =
        Module.concat(
          __MODULE__,
          :"TimedProjectCompileMixProject#{System.unique_integer([:positive])}"
        )

      app = :"timed_project_compile_#{System.unique_integer([:positive])}"

      write_mix_project!(tmp_dir, project_module, app)
      source_path = Path.join([tmp_dir, "lib", "timed_project_compile.ex"])
      File.mkdir_p!(Path.dirname(source_path))

      File.write!(source_path, """
      defmodule #{inspect(module)} do
        def value, do: :ok
      end
      """)

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.new()
      Engine.set_project(project)
      test_pid = self()
      token = System.unique_integer([:positive])

      patch(Engine.Dispatch, :erpc_call, fn
        Expert.Progress, :begin, _args ->
          {:ok, token}

        Expert.Progress, :report, [^token, opts] ->
          send(test_pid, {:progress_report, opts})
          :ok

        Expert.Progress, :report, _args ->
          :ok
      end)

      patch(Engine.Dispatch, :erpc_cast, fn
        Expert.Progress, :log_info, [message] ->
          send(test_pid, {:info_log, message})
          true

        Expert.Progress, :complete, [_token, opts] ->
          send(test_pid, {:progress_complete, opts})
          true
      end)

      assert {:ok, []} = Engine.Build.Project.compile(project, false)

      assert_receive {:progress_report, [message: "Compiling " <> _]}, 500
      assert_receive {:progress_report, [message: "mix compile took " <> _]}, 500
      assert_receive {:progress_complete, [message: "Compilation finished in " <> _]}, 500
    end
  end

  defp compile_project_file(root, path) do
    root
    |> project()
    |> Engine.set_project()

    Tracers.with([ProjectTracer], fn -> Code.compile_file(path) end)
  end

  defp compile_project_string(root, contents, path) do
    root
    |> project()
    |> Engine.set_project()

    Tracers.with([ProjectTracer], fn -> Code.compile_string(contents, path) end)
  end

  defp project(root) do
    root |> Forge.Document.Path.to_uri() |> Project.bare()
  end

  defp native_join(path_segments) do
    path_segments
    |> Path.join()
    |> Forge.Path.native()
  end

  defp write_mix_project!(root, module, app) do
    File.write!(Path.join(root, "mix.exs"), """
    defmodule #{inspect(module)} do
      use Mix.Project

      def project do
        [app: #{inspect(app)}, version: "0.1.0"]
      end
    end
    """)
  end

  defp write_partition_project!(root, project_module, app, dep_apps) do
    deps =
      Enum.map(dep_apps, fn dep_app ->
        dep_name = Atom.to_string(dep_app)
        {dep_app, [path: "deps/#{dep_name}", compile: "elixir record_partition.exs"]}
      end)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule #{inspect(project_module)} do
      use Mix.Project

      def project do
        [app: #{inspect(app)}, version: "0.1.0", deps: #{inspect(deps)}]
      end
    end
    """)

    Enum.each(dep_apps, &write_partition_dependency!(root, &1))
  end

  defp write_partition_dependency!(root, dep_app) do
    dep_root = Path.join([root, "deps", Atom.to_string(dep_app)])
    File.mkdir_p!(Path.join(dep_root, "ebin"))

    File.write!(Path.join([dep_root, "ebin", "#{dep_app}.app"]), """
    {application, #{dep_app}, [{applications, [kernel, stdlib]}, {vsn, "0.1.0"}, {modules, []}]}.
    """)

    File.write!(Path.join(dep_root, "mix.exs"), """
    defmodule #{[dep_app, :MixProject] |> Module.concat() |> inspect()} do
      use Mix.Project

      def project do
        [app: #{inspect(dep_app)}, version: "0.1.0"]
      end
    end
    """)

    File.write!(Path.join(dep_root, "record_partition.exs"), """
    File.write!("partition_count.txt", System.get_env(#{inspect(@dependency_compile_partition_env)}) || "unset")
    """)
  end

  defp path_dependency_project!(tmp_dir) do
    unique = System.unique_integer([:positive])
    app_root = native_join([tmp_dir, "app_#{unique}"])
    dep_app = :"deps_loadpaths_trace_dep_#{unique}"
    dep_name = Atom.to_string(dep_app)
    dep_root = Path.join([app_root, "deps", dep_name])
    source_path = native_join([dep_root, "lib", "deps_loadpaths_trace.ex"])

    project_module = Module.concat(__MODULE__, :"DepsLoadpathsTraceMixProject#{unique}")
    dep_project_module = Module.concat(__MODULE__, :"DepsLoadpathsTraceDepMixProject#{unique}")
    dep_module = Module.concat(__MODULE__, :"DepsLoadpathsTraceDep#{unique}")
    app = :"deps_loadpaths_trace_#{unique}"

    File.mkdir_p!(Path.dirname(source_path))

    File.write!(Path.join(app_root, "mix.exs"), """
    defmodule #{inspect(project_module)} do
      use Mix.Project

      def project do
        [app: #{inspect(app)}, version: "0.1.0", deps: deps()]
      end

      defp deps do
        [{#{inspect(dep_app)}, path: "deps/#{dep_name}"}]
      end
    end
    """)

    File.write!(Path.join(dep_root, "mix.exs"), """
    defmodule #{inspect(dep_project_module)} do
      use Mix.Project

      def project do
        [app: #{inspect(dep_app)}, version: "0.1.0"]
      end
    end
    """)

    File.write!(source_path, """
    defmodule #{inspect(dep_module)} do
      def value, do: :ok
    end
    """)

    %{
      dep_module: dep_module,
      project: app_root |> Forge.Document.Path.to_uri() |> Project.new(),
      project_module: project_module,
      source_path: source_path
    }
  end

  defp module_definition(path, module) do
    Entry.definition(
      path,
      Block.root(),
      module,
      :module,
      test_range(),
      nil
    )
  end

  defp reference(path, subject) do
    Entry.reference(
      path,
      Block.root(),
      subject,
      {:function, :usage},
      test_range(),
      nil
    )
  end

  defp reference_entry(subject) do
    Enum.find(SearchBackend.entries(), fn entry ->
      entry.subject == subject and entry.type == {:function, :usage} and
        entry.subtype == :reference
    end)
  end

  defp source_column(source, line_number, token) do
    source
    |> String.split("\n")
    |> Enum.at(line_number - 1)
    |> :binary.match(token)
    |> elem(0)
    |> Kernel.+(1)
  end

  defp test_range do
    Range.new(
      %Position{line: 1, character: 1, starting_index: 1},
      %Position{line: 1, character: 2, starting_index: 1}
    )
  end

  defp restore_env(name, {:ok, value}), do: System.put_env(name, value)
  defp restore_env(name, :error), do: System.delete_env(name)

  defp patch_progress do
    token = System.unique_integer([:positive])

    patch(Engine.Dispatch, :erpc_call, fn
      Expert.Progress, :begin, _args -> {:ok, token}
      Expert.Progress, :report, _args -> :ok
    end)

    patch(Engine.Dispatch, :erpc_cast, fn
      Expert.Progress, _function, _args -> true
    end)
  end

  defp assert_progress_reported(fun) do
    token = System.unique_integer([:positive])
    test_pid = self()

    patch(Engine.Dispatch, :erpc_call, fn
      Expert.Progress, :report, [^token, opts] ->
        send(test_pid, {:progress_report, opts})
        :ok

      Expert.Progress, :report, _args ->
        :ok
    end)

    Build.set_progress_token(token)

    try do
      fun.()
    after
      Build.clear_progress_token()
    end

    assert_receive {:progress_report, [message: "compiling: " <> _]}, 500
  end
end
