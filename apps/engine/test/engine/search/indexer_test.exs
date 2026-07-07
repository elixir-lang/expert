defmodule Engine.Search.IndexerTest do
  use ExUnit.Case
  use Forge.Test.EventualAssertions
  use Patch

  import Forge.Test.Fixtures

  alias Engine.Compilation.TraceBuffer
  alias Engine.Dispatch
  alias Engine.Search.Fuzzy
  alias Engine.Search.Indexer
  alias Engine.Search.Indexer.Beams
  alias Engine.Search.Indexer.Manifest
  alias Engine.Search.Indexer.Manifest.Entry, as: ManifestEntry
  alias Engine.Search.Indexer.ManifestStore
  alias Engine.Search.Indexer.Sources
  alias Engine.Test.SearchBackend, as: FakeBackend
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Formats
  alias Forge.Project
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Indexer.Source.Block

  setup do
    project = project()
    start_supervised!(Engine.ApplicationCache)
    start_supervised!(TraceBuffer)
    start_supervised(Dispatch)

    patch(Engine.Api.Proxy, :broadcast, fn _ -> :ok end)

    patch(Dispatch, :erpc_call, fn
      Expert.Progress, :begin, [_title, _opts] ->
        {:ok, System.unique_integer([:positive])}

      Expert.Progress, :report, _args ->
        :ok
    end)

    patch(Engine.ManagerApi, :search_store_commit_traces, fn _project, trace_updates ->
      FakeBackend.commit_traces(trace_updates)
    end)

    patch(Dispatch, :erpc_cast, fn Expert.Progress, _function, _args -> true end)
    FakeBackend.set_entries([])
    ManifestStore.invalidate(project)
    {:ok, project: project}
  end

  defp create_index(project) do
    assert {:ok, entries, manifest} = Indexer.create_index(project)
    assert :ok = Indexer.commit_manifest(project, manifest)

    entries
  end

  defp start_store!(%Project{}), do: :ok

  defp load_store_after_trace_commit!(%Project{} = project) do
    assert :ok = TraceBuffer.commit_project(project)
    FakeBackend.entries()
  end

  defp update_index(project, path_to_ids \\ FakeBackend.path_to_ids()) do
    assert {:ok, entries, paths_to_clear, manifest} =
             Indexer.update_index(project, path_to_ids)

    assert :ok = Indexer.commit_manifest(project, manifest)
    {entries, paths_to_clear}
  end

  defp write_file!(path, contents) do
    path = Forge.Path.native(path)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp write_mix_project!(root, module_name, project_config) do
    write_file!(Path.join(root, "mix.exs"), """
    defmodule #{module_name} do
      use Mix.Project

      def project do
        #{project_config}
      end
    end
    """)
  end

  defp mix_build_file!(root, relative_path, config) do
    build_root =
      File.cd!(root, fn ->
        config
        |> Keyword.put_new(:build_per_environment, true)
        |> Mix.Project.build_path()
        |> Path.dirname()
      end)

    [build_root | List.wrap(relative_path)]
    |> Path.join()
    |> Forge.Path.native()
  end

  describe "create_index/1" do
    test "returns a list of entries", %{project: project} do
      entry_stream = create_index(project)
      entries = Enum.to_list(entry_stream)
      project_root = Project.root_path(project)

      assert not Enum.empty?(entries)
      assert Enum.all?(entries, fn entry -> String.starts_with?(entry.path, project_root) end)
    end

    test "entries are either .ex or .exs files", %{project: project} do
      entries = create_index(project)
      assert Enum.all?(entries, fn entry -> Path.extname(entry.path) in [".ex", ".exs"] end)
    end

    test "indexes bare projects without treating root/deps as a dependency directory" do
      bare_root = native_join([fixtures_path(), "scratch"])
      bare_project = bare_root |> Forge.Document.Path.to_uri() |> Project.bare()

      patch(Engine, :get_project, fn -> bare_project end)

      entries = create_index(bare_project)
      assert Enum.any?(entries, &(&1.path == native_join([bare_root, "bare_file.ex"])))
    end

    test "reports search indexing progress and detailed index info", %{project: project} do
      test_pid = self()

      patch(Dispatch, :erpc_call, fn
        Expert.Progress, :begin, [title, opts] ->
          send(test_pid, {:progress_begin, title, opts})
          {:ok, System.unique_integer([:positive])}

        Expert.Progress, :report, _args ->
          :ok
      end)

      patch(Dispatch, :erpc_cast, fn
        Expert.Progress, :log_info, [message] ->
          send(test_pid, {:info_log, message})
          true

        Expert.Progress, :complete, [_token, opts] ->
          send(test_pid, {:progress_complete, opts})
          true
      end)

      create_index(project)

      assert_received {:progress_begin, "Indexing search inputs", _opts}
      assert_received {:progress_complete, [message: "Indexed " <> indexed_message]}
      assert indexed_message =~ ~r/^\d+ files? in /

      assert_received {:info_log, "Indexed search inputs: " <> detail_message}
      assert detail_message =~ ~r/^\d+ source files? in /
      assert detail_message =~ ~r/; \d+ BEAM files? in /
    end

    @tag :tmp_dir
    test "indexes active path dependency beams", %{tmp_dir: tmp_dir} do
      %{module: module, project: project} = with_beam_dependency(tmp_dir)

      entries = create_index(project)

      assert Enum.any?(entries, &(&1.subject == module and &1.subtype == :definition))

      assert Enum.any?(
               entries,
               &(&1.subject == Forge.Formats.mfa(module, :public_fun, 0) and
                   &1.subtype == :definition)
             )

      refute Enum.any?(entries, &(&1.subject == Forge.Formats.mfa(module, :private_fun, 0)))
    end

    @tag :tmp_dir
    test "does not reindex dependency beams already indexed by traces", %{tmp_dir: tmp_dir} do
      %{beam_path: beam_path, dep_file: dep_file, module: module, project: project} =
        with_beam_dependency(tmp_dir,
          dep_source: fn module ->
            """
            defmodule #{inspect(module)} do
              def values(values), do: Enum.map(values, & &1)
            end
            """
          end,
          rewrite_source?: false
        )

      ManifestStore.invalidate(project)
      start_store!(project)

      TraceBuffer.add_definitions(dep_file, module, [module_definition(dep_file, module)])
      TraceBuffer.add_beam_path(dep_file, beam_path)

      entries = load_store_after_trace_commit!(project)

      assert [_entry] =
               Enum.filter(
                 entries,
                 &(&1.subject == module and &1.type == :module and &1.subtype == :definition)
               )

      refute Enum.any?(entries, &(&1.subject == Formats.mfa(module, :values, 1)))
    end

    @tag :tmp_dir
    test "does not reindex traced dependency beams during update plan expansion", %{
      tmp_dir: tmp_dir
    } do
      %{beam_path: beam_path, dep_file: dep_file, module: module, project: project} =
        with_beam_dependency(tmp_dir,
          dep_source: fn module ->
            """
            defmodule #{inspect(module)} do
              def values(values), do: Enum.map(values, & &1)
            end
            """
          end,
          rewrite_source?: false
        )

      entries = create_index(project)
      FakeBackend.set_entries(Enum.to_list(entries))
      start_store!(project)

      new_module = Module.concat(BeamDependencyIndexerTest, :NewDepDuringUpdate)
      new_file = dep_file |> Path.dirname() |> Path.join("new_dep_during_update.ex")

      write_file!(new_file, """
      defmodule #{inspect(new_module)} do
        def value, do: :ok
      end
      """)

      assert {:ok, [^new_module], %{compile_warnings: [], runtime_warnings: []}} =
               Kernel.ParallelCompiler.compile_to_path([new_file], Path.dirname(beam_path),
                 return_diagnostics: true
               )

      TraceBuffer.add_definitions(dep_file, module, [module_definition(dep_file, module)])
      TraceBuffer.add_beam_path(dep_file, beam_path)

      load_store_after_trace_commit!(project)
      {updated_entries, _paths_to_clear} = update_index(project)

      assert Enum.any?(updated_entries, &(&1.subject == new_module))
      refute Enum.any?(updated_entries, &(&1.subject == Formats.mfa(module, :values, 1)))
    end

    @tag :tmp_dir
    test "does not duplicate traced project entries with discovered project beams", %{
      tmp_dir: tmp_dir
    } do
      module = Module.concat(TraceProjectIndexerTest, :ExpertLike)
      project_module = Module.concat(TraceProjectIndexerTest, :MixProject)
      app_root = native_join([tmp_dir, "trace_project"])
      source_path = native_join([app_root, "lib", "expert_like.ex"])

      write_mix_project!(
        app_root,
        inspect(project_module),
        ~s([app: :trace_project_indexer_test, version: "0.1.0"])
      )

      Module.create(
        project_module,
        quote do
          def project do
            [app: :trace_project_indexer_test, version: "0.1.0"]
          end
        end,
        Macro.Env.location(__ENV__)
      )

      write_file!(source_path, """
      defmodule #{inspect(module)} do
        def handle_request(request, lsp) do
          {request, lsp}
        end
      end
      """)

      project =
        app_root
        |> Forge.Document.Path.to_uri()
        |> Project.new()
        |> Project.set_project_module(project_module)

      {:ok, build_path} = Engine.Mix.in_project(project, fn _ -> Mix.Project.build_path() end)
      ebin_path = Path.join([build_path, "lib", "trace_project_indexer_test", "ebin"])
      File.mkdir_p!(ebin_path)

      compiler_options = Code.compiler_options()

      try do
        Code.compiler_options(
          debug_info: true,
          parser_options: [columns: true, token_metadata: true]
        )

        assert {:ok, [^module], %{compile_warnings: [], runtime_warnings: []}} =
                 Kernel.ParallelCompiler.compile_to_path([source_path], ebin_path,
                   return_diagnostics: true
                 )
      after
        Code.compiler_options(compiler_options)
      end

      beam_path = Path.join(ebin_path, Atom.to_string(module) <> ".beam")

      beam = File.read!(beam_path)
      {:ok, definitions} = Beams.extract_definitions_from_binary(beam, include_private?: true)

      ManifestStore.invalidate(project)
      start_store!(project)

      TraceBuffer.add_definitions(source_path, module, definitions)
      TraceBuffer.add_beam_path(source_path, beam_path)

      entries = load_store_after_trace_commit!(project)
      subject = Formats.mfa(module, :handle_request, 2)

      assert [%Entry{range: range}] =
               Enum.filter(
                 entries,
                 &(&1.subject == subject and &1.type == {:function, :public} and
                     &1.subtype == :definition)
               )

      assert range.start.line == 2
      assert range.start.character == 7
    end

    @tag :tmp_dir
    test "does not duplicate traced project entries when trace paths are relative", %{
      tmp_dir: tmp_dir
    } do
      module = Module.concat(TraceProjectIndexerTest, :RelativeTracePath)

      %{beam_path: beam_path, project: project, source_path: source_path} =
        with_project_beam(tmp_dir,
          module: module,
          source: """
          defmodule #{inspect(module)} do
            def value, do: :ok
          end
          """
        )

      beam = File.read!(beam_path)
      {:ok, definitions} = Beams.extract_definitions_from_binary(beam, include_private?: true)

      app_root = Project.root_path(project)
      relative_source_path = Path.relative_to(source_path, app_root)
      relative_beam_path = Path.relative_to(beam_path, app_root)
      ManifestStore.invalidate(project)
      start_store!(project)

      File.cd!(app_root, fn ->
        TraceBuffer.add_definitions(relative_source_path, module, definitions)
        TraceBuffer.add_beam_path(relative_source_path, relative_beam_path)
      end)

      entries = load_store_after_trace_commit!(project)
      subject = Formats.mfa(module, :value, 0)

      assert [%Entry{path: ^source_path}] =
               Enum.filter(
                 entries,
                 &(&1.subject == subject and &1.type == {:function, :public} and
                     &1.subtype == :definition)
               )
    end

    @tag :tmp_dir
    test "does not duplicate traced source outputs with discovered beam entries", %{
      tmp_dir: tmp_dir
    } do
      module = Module.concat(TraceProjectIndexerTest, :TracedOutputOwner)

      %{beam_path: beam_path, project: project, source_path: source_path} =
        with_project_beam(tmp_dir,
          module: module,
          source: """
          defmodule #{inspect(module)} do
            def handle_request(request, lsp) when is_atom(request), do: {request, lsp}
            def handle_request(request, lsp) when is_binary(request), do: {request, lsp}
            def handle_request(request, lsp), do: {request, lsp}
          end
          """
        )

      beam = File.read!(beam_path)
      {:ok, definitions} = Beams.extract_definitions_from_binary(beam, include_private?: true)

      ManifestStore.invalidate(project)
      start_store!(project)

      TraceBuffer.add_definitions(source_path, module, definitions)

      entries = load_store_after_trace_commit!(project)
      subject = Formats.mfa(module, :handle_request, 2)

      definitions =
        entries
        |> Enum.filter(
          &(&1.subject == subject and &1.type == {:function, :public} and
              &1.subtype == :definition)
        )
        |> Enum.sort_by(& &1.range.start.line)

      assert [first, second, third] = definitions
      assert [first.path, second.path, third.path] == [source_path, source_path, source_path]

      assert [first.range.start.line, second.range.start.line, third.range.start.line] == [
               2,
               3,
               4
             ]

      assert {:ok, manifest} = ManifestStore.load(project)
      assert :error = Manifest.fetch(manifest, beam_path)

      assert [%ManifestEntry{kind: :source, input_path: ^source_path}] =
               Enum.filter(Manifest.entries(manifest), &(&1.output_path == source_path))
    end

    @tag :tmp_dir
    test "does not send trace-covered source paths to the source indexer", %{
      tmp_dir: tmp_dir
    } do
      module = Module.concat(TraceProjectIndexerTest, :TraceCoveredSource)
      source_path = native_join([tmp_dir, "lib", "trace_covered_source.ex"])

      write_file!(source_path, "defmodule #{inspect(module)} do end")

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.bare()
      test_pid = self()

      patch(Sources, :index, fn paths ->
        send(test_pid, {:source_index_paths, paths})
        {[], []}
      end)

      ManifestStore.invalidate(project)
      start_store!(project)

      TraceBuffer.add_definitions(source_path, module, [module_definition(source_path, module)])

      entries = load_store_after_trace_commit!(project)
      update_index(project)

      assert_received {:source_index_paths, []}
      assert Enum.any?(entries, &(&1.path == source_path and &1.subject == module))
    end

    @tag :tmp_dir
    test "records source manifest entries for trace-covered files without beam output", %{
      tmp_dir: tmp_dir
    } do
      module = Module.concat(TraceProjectIndexerTest, :StaleManifestClearOnly)
      source_path = native_join([tmp_dir, "lib", "stale_manifest_clear_only.ex"])

      write_file!(source_path, "defmodule #{inspect(module)} do end")

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.bare()

      ManifestStore.invalidate(project)
      start_store!(project)

      TraceBuffer.add_definitions(source_path, module, [module_definition(source_path, module)])
      assert Enum.any?(load_store_after_trace_commit!(project), &(&1.subject == module))

      TraceBuffer.clear(source_path)

      assert :ok = TraceBuffer.commit_project(project)

      assert_eventually(not Enum.any?(FakeBackend.entries(), &(&1.subject == module)), 500)

      assert {:ok, manifest} = ManifestStore.load(project)

      assert [
               %ManifestEntry{kind: :source, input_path: ^source_path, output_path: ^source_path}
             ] = Manifest.entries(manifest)

      test_pid = self()

      patch(Sources, :index, fn paths ->
        send(test_pid, {:source_index_paths, paths})
        {[], []}
      end)

      assert {[], []} = update_index(project)
      assert_received {:source_index_paths, []}
    end

    @tag :tmp_dir
    test "indexes untraced project beam definitions for workspace symbols", %{tmp_dir: tmp_dir} do
      module = Module.concat(ProjectBeamIndexerTest, :WorkspaceSymbol)

      %{project: project} =
        with_project_beam(tmp_dir,
          module: module,
          source: """
          defmodule #{inspect(module)} do
            def handle_request(request, lsp) do
              {request, lsp}
            end
          end
          """
        )

      entries = create_index(project)
      subject = Formats.mfa(module, :handle_request, 2)

      assert [%Entry{id: id, range: range}] =
               Enum.filter(
                 entries,
                 &(&1.subject == subject and &1.type == {:function, :public} and
                     &1.subtype == :definition)
               )

      assert range.start.line == 2
      assert range.start.character == 7

      assert [^id] = entries |> Fuzzy.from_entries() |> Fuzzy.match("handle_request")
    end

    @tag :tmp_dir
    test "adds source references for untraced project beams", %{tmp_dir: tmp_dir} do
      module = Module.concat(ProjectBeamIndexerTest, :ReferenceFallback)

      %{project: project} =
        with_project_beam(tmp_dir,
          module: module,
          source: """
          defmodule #{inspect(module)} do
            def values(values) do
              Enum.map(values, & &1)
            end
          end
          """
        )

      entries = create_index(project)

      assert Enum.any?(
               entries,
               &(&1.subject == Formats.mfa(Enum, :map, 2) and
                   &1.type == {:function, :usage} and &1.subtype == :reference)
             )
    end

    @tag :tmp_dir
    test "adds source references from mix project .exs files", %{tmp_dir: tmp_dir} do
      %{project: project, reference_subject: reference_subject, test_path: test_path} =
        with_test_script_reference_project(tmp_dir)

      entries = create_index(project)

      assert Enum.any?(entries, &source_reference?(&1, test_path, reference_subject))
    end

    @tag :tmp_dir
    test "does not parse source references for traced project beams", %{tmp_dir: tmp_dir} do
      module = Module.concat(ProjectBeamIndexerTest, :TracedNoFallback)

      %{beam_path: beam_path, project: project, source_path: source_path} =
        with_project_beam(tmp_dir,
          module: module,
          source: """
          defmodule #{inspect(module)} do
            def values(values), do: Enum.map(values, & &1)
          end
          """
        )

      beam = File.read!(beam_path)
      {:ok, definitions} = Beams.extract_definitions_from_binary(beam, include_private?: true)

      ManifestStore.invalidate(project)
      start_store!(project)

      TraceBuffer.add_definitions(source_path, module, definitions)
      TraceBuffer.add_beam_path(source_path, beam_path)

      entries = load_store_after_trace_commit!(project)

      assert Enum.any?(entries, &(&1.subject == Formats.mfa(module, :values, 1)))
      refute Enum.any?(entries, &(&1.subject == Formats.mfa(Enum, :map, 2)))
    end

    @tag :tmp_dir
    test "preserves source manifest entries when refreshing with stale project beams", %{
      tmp_dir: tmp_dir
    } do
      module = Module.concat(ProjectBeamIndexerTest, :LiveRefresh)
      updated_module = Module.concat(ProjectBeamIndexerTest, :LiveRefreshUpdated)

      %{beam_path: beam_path, project: project, source_path: source_path} =
        with_project_beam(tmp_dir,
          module: module,
          source: "defmodule #{inspect(module)} do\n  def value, do: :ok\nend\n"
        )

      {_beam_entries, beam_manifest_entries} = Beams.index([beam_path])
      assert :ok = ManifestStore.commit(project, Manifest.new(beam_manifest_entries))

      File.write!(
        source_path,
        "defmodule #{inspect(updated_module)} do\n  def value, do: :ok\nend\n"
      )

      File.touch!(source_path, {{2100, 1, 1}, {0, 0, 0}})

      assert {:ok, source_entry} = Manifest.Entry.source(source_path)
      assert {:ok, manifest} = ManifestStore.load(project)

      assert :ok =
               ManifestStore.commit(
                 project,
                 Manifest.replace_output(manifest, source_path, [source_entry])
               )

      FakeBackend.set_entries([module_definition(source_path, updated_module)])

      assert {_updated_entries, []} = update_index(project)

      assert Enum.any?(FakeBackend.entries(), &(&1.subject == updated_module))
      refute Enum.any?(FakeBackend.entries(), &(&1.subject == module))
    end

    @tag :tmp_dir
    test "does not parse source references for dependency beams", %{tmp_dir: tmp_dir} do
      %{module: module, project: project} =
        with_beam_dependency(tmp_dir,
          dep_source: fn module ->
            """
            defmodule #{inspect(module)} do
              def values(values), do: Enum.map(values, & &1)
            end
            """
          end,
          rewrite_source?: false
        )

      entries = create_index(project)

      assert Enum.any?(entries, &(&1.subject == module and &1.subtype == :definition))
      refute Enum.any?(entries, &(&1.subject == Formats.mfa(Enum, :map, 2)))
    end

    @tag :tmp_dir
    test "does not index dependency beams when the dependency has app false", %{tmp_dir: tmp_dir} do
      %{module: module, project: project} =
        with_beam_dependency(tmp_dir, dep_opts: [path: "deps/beam_dep", app: false])

      entries = create_index(project)

      refute Enum.any?(entries, &(&1.subject == module and &1.subtype == :definition))
    end

    @tag :tmp_dir
    test "indexes protocol callback definitions from beam metadata", %{tmp_dir: tmp_dir} do
      %{module: protocol, project: project} = with_protocol_beam_dependency(tmp_dir)

      entries = create_index(project)

      assert Enum.any?(entries, &(&1.subject == protocol and &1.type == {:protocol, :definition}))

      assert Enum.any?(
               entries,
               &(&1.subject == Forge.Formats.mfa(protocol, :run, 1) and
                   &1.type == {:function, :public} and &1.subtype == :definition)
             )

      refute Enum.any?(entries, &(&1.subject == Forge.Formats.mfa(protocol, :impl_for, 1)))
      refute Enum.any?(entries, &(&1.subject == Forge.Formats.mfa(protocol, :impl_for!, 1)))
      refute Enum.any?(entries, &(&1.subject == Forge.Formats.mfa(protocol, :__protocol__, 1)))
    end

    @tag :tmp_dir
    test "indexes protocol implementations from beam metadata", %{tmp_dir: tmp_dir} do
      %{impl_module: impl_module, project: project, protocol: protocol} =
        with_protocol_implementation_beam_dependency(tmp_dir)

      entries = create_index(project)

      assert Enum.any?(
               entries,
               &(&1.subject == protocol and &1.type == {:protocol, :implementation} and
                   &1.subtype == :definition)
             )

      assert Enum.any?(
               entries,
               &(&1.subject == impl_module and &1.type == :module and &1.subtype == :definition)
             )

      refute Enum.any?(
               entries,
               &(&1.subject == impl_module and &1.type == {:protocol, :implementation})
             )
    end

    @tag :tmp_dir
    test "locates protocol implementation definitions on defimpl", %{tmp_dir: tmp_dir} do
      %{dep_file: dep_file, project: project, protocol: protocol} =
        with_protocol_implementation_beam_dependency(tmp_dir, rewrite_source?: false)

      line = line_containing(dep_file, "defimpl")
      expected_column = expected_column(dep_file, "defimpl")
      expected_length = line |> String.trim() |> String.length()

      entries = create_index(project)

      entry =
        Enum.find(entries, &(&1.subject == protocol and &1.type == {:protocol, :implementation}))

      assert %Entry{range: range, subtype: :definition} = entry
      assert range.start.character == expected_column
      assert range.end.character == expected_column + expected_length
    end

    @tag :tmp_dir
    test "indexes entries from transitive dependency beams", %{tmp_dir: tmp_dir} do
      %{module: module, project: project} = with_transitive_beam_dependency(tmp_dir)

      entries = create_index(project)
      assert Enum.any?(entries, &(&1.subject == module and &1.subtype == :definition))
    end

    @tag :tmp_dir
    test "locates beam module definitions on the module name", %{tmp_dir: tmp_dir} do
      %{dep_file: dep_file, module: module, project: project} =
        with_beam_dependency(tmp_dir, rewrite_source?: false)

      module_name = inspect(module)
      expected_column = expected_column(dep_file, module_name)

      entries = create_index(project)
      entry = Enum.find(entries, &(&1.subject == module and &1.type == :module))

      assert %Entry{range: range, subtype: :definition} = entry
      assert range.start.character == expected_column
      assert range.end.character == expected_column + String.length(module_name)
    end

    @tag :tmp_dir
    test "locates nested beam module definitions on the nested module name", %{tmp_dir: tmp_dir} do
      %{dep_file: dep_file, module: module, project: project} =
        with_nested_beam_dependency(tmp_dir)

      expected_column = expected_column(dep_file, "Inner")

      entries = create_index(project)
      entry = Enum.find(entries, &(&1.subject == module and &1.type == :module))

      assert %Entry{range: range, subtype: :definition} = entry
      assert range.start.character == expected_column
      assert range.end.character == expected_column + String.length("Inner")
    end

    @tag :tmp_dir
    test "caches dependency beams with no debug metadata", %{tmp_dir: tmp_dir} do
      %{beam_path: beam_path, module: module, project: project} =
        with_beam_dependency(tmp_dir, debug_info?: false, rewrite_source?: false)

      assert {entries, []} = update_index(project)
      assert {:ok, manifest} = ManifestStore.load(project)

      refute Enum.any?(entries, &(&1.subject == module))

      assert {:ok, %ManifestEntry{kind: :beam, output_path: nil}} =
               Manifest.fetch(manifest, beam_path)
    end

    @tag :tmp_dir
    test "caches stale dependency beams without entries", %{tmp_dir: tmp_dir} do
      %{beam_path: beam_path, dep_file: dep_file, module: module, project: project} =
        with_beam_dependency(tmp_dir, rewrite_source?: false)

      File.touch!(dep_file, {{2100, 1, 1}, {0, 0, 0}})

      assert {entries, []} = update_index(project)
      assert {:ok, manifest} = ManifestStore.load(project)

      refute Enum.any?(entries, &(&1.subject == module))

      assert {:ok, %ManifestEntry{kind: :beam, output_path: nil, source_path: ^dep_file}} =
               Manifest.fetch(manifest, beam_path)
    end

    @tag :tmp_dir
    test "does not reindex unchanged skipped dependency beams after caching them", %{
      tmp_dir: tmp_dir
    } do
      %{beam_path: beam_path, project: project} =
        with_beam_dependency(tmp_dir, debug_info?: false, rewrite_source?: false)

      assert {entries, []} = update_index(project)
      FakeBackend.set_entries(entries)
      assert {:ok, manifest} = ManifestStore.load(project)

      old_manifest_entries =
        manifest
        |> Manifest.entries()
        |> Enum.reject(&(&1.input_path == beam_path))

      assert :ok = ManifestStore.commit(project, Manifest.new(old_manifest_entries))

      test_pid = self()

      patch(Dispatch, :erpc_call, fn
        Expert.Progress, :begin, ["Indexing BEAM metadata", _opts] ->
          send(test_pid, :dependency_progress_begin)
          {:ok, System.unique_integer([:positive])}

        Expert.Progress, :begin, [_title, _opts] ->
          {:ok, System.unique_integer([:positive])}

        Expert.Progress, :report, _args ->
          :ok
      end)

      assert {entries, []} = update_index(project)
      assert [] = entries
      assert_receive :dependency_progress_begin
      refute_receive :dependency_progress_begin, 0

      assert {entries, []} = update_index(project)
      assert [] = entries
      refute_receive :dependency_progress_begin
    end

    @tag :tmp_dir
    test "clears entries when beam metadata disappears", %{tmp_dir: tmp_dir} do
      %{beam_path: beam_path, dep_file: dep_file, project: project} =
        with_beam_dependency(tmp_dir)

      entries = create_index(project)
      FakeBackend.set_entries(entries)

      File.rm!(beam_path)

      assert {_entries, paths_to_clear} = update_index(project)
      assert dep_file in paths_to_clear
    end

    @tag :tmp_dir
    test "clears entries when beam metadata is stale", %{tmp_dir: tmp_dir} do
      %{dep_file: dep_file, project: project} = with_beam_dependency(tmp_dir)

      entries = create_index(project)
      FakeBackend.set_entries(entries)

      File.touch!(dep_file, {{2100, 1, 1}, {0, 0, 0}})

      assert {[], paths_to_clear} = update_index(project)
      assert dep_file in paths_to_clear
    end

    @tag :tmp_dir
    test "clears entries when a dependency is removed but its beam remains", %{tmp_dir: tmp_dir} do
      %{app_root: app_root, beam_path: beam_path, dep_file: dep_file, project: project} =
        with_beam_dependency(tmp_dir)

      entries = create_index(project)
      FakeBackend.set_entries(entries)

      project = project_without_beam_dependency(app_root)

      assert File.exists?(beam_path)
      assert {_entries, paths_to_clear} = update_index(project)
      assert dep_file in paths_to_clear
    end

    @tag :tmp_dir
    test "retains entries from remaining beams for the same source", %{tmp_dir: tmp_dir} do
      %{
        beam_paths: [removed_beam_path, kept_beam_path],
        modules: [removed_module, kept_module],
        project: project
      } = with_beam_dependency(tmp_dir, module_count: 2)

      entries = create_index(project)
      FakeBackend.set_entries(entries)

      File.rm!(removed_beam_path)

      assert {updated_entries, []} = update_index(project)

      assert Enum.any?(
               updated_entries,
               &(&1.subject == kept_module and &1.subtype == :definition)
             )

      refute Enum.any?(updated_entries, &(&1.subject == removed_module))

      assert File.exists?(kept_beam_path)
      refute File.exists?(removed_beam_path)
    end
  end

  describe "update_index/2 with dependency beams" do
    test "reindexes beam siblings sharing source" do
      tmp_dir = Path.join(System.tmp_dir!(), "indexer-#{unique_id()}")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      parent = Module.concat(BeamDependencyIndexerTest, :SiblingParent)
      child = Module.concat(parent, :Child)

      dep_source = """
      defmodule #{inspect(parent)} do
        def parent_fun, do: :ok

        defmodule Child do
          def child_fun, do: :ok
        end
      end
      """

      %{beam_paths: beam_paths, project: project} =
        with_beam_dependency(tmp_dir,
          module: parent,
          modules: [parent, child],
          expected_modules: [parent, child],
          rewrite_source?: false,
          dep_source: dep_source
        )

      parent_beam_path =
        Enum.find(beam_paths, &String.ends_with?(&1, Atom.to_string(parent) <> ".beam"))

      child_beam_path =
        Enum.find(beam_paths, &String.ends_with?(&1, Atom.to_string(child) <> ".beam"))

      assert is_binary(parent_beam_path)
      assert is_binary(child_beam_path)

      {parent_entries, parent_manifest_entries} = Beams.index([parent_beam_path])
      FakeBackend.set_entries(parent_entries)
      assert :ok = ManifestStore.commit(project, Manifest.new(parent_manifest_entries))

      assert {updated_entries, []} = update_index(project)
      updated_entries = Enum.to_list(updated_entries)

      assert Enum.any?(updated_entries, &(&1.subject == parent and &1.subtype == :definition))
      assert Enum.any?(updated_entries, &(&1.subject == child and &1.subtype == :definition))
    end
  end

  @ephemeral_file_name "ephemeral.exs"

  def with_an_ephemeral_file(%{project: project}, file_contents) do
    file_path = native_join([Project.root_path(project), "lib", @ephemeral_file_name])
    File.write!(file_path, file_contents)

    on_exit(fn ->
      File.rm(file_path)
    end)

    {:ok, file_path: file_path}
  end

  defp module_definition(file_path, module) do
    Entry.definition(
      file_path,
      Block.root(),
      module,
      :module,
      Range.new(
        %Position{line: 1, character: 1, starting_index: 1},
        %Position{line: 1, character: 2, starting_index: 1}
      ),
      nil
    )
  end

  def with_a_file_with_a_module(context) do
    file_contents = ~s[
        defmodule Ephemeral do
        end
      ]

    with_an_ephemeral_file(context, file_contents)
  end

  def with_an_existing_index(%{project: project}) do
    entries = create_index(project)
    FakeBackend.set_entries(entries)

    {:ok, entries: entries}
  end

  describe "update_index/2 removes paths that became non-indexable" do
    @tag :tmp_dir
    test "deletes previously indexed configured build files even when they still exist", %{
      tmp_dir: tmp_dir
    } do
      source_file = native_join([tmp_dir, "lib", "source_file.ex"])
      build_file = mix_build_file!(tmp_dir, "stale.ex", build_path: "custom_build")

      write_mix_project!(
        tmp_dir,
        "StaleConfiguredBuildPathIndexerTest.MixProject",
        ~s([app: :stale_configured_build_path_indexer_test, version: "0.1.0", build_path: "custom_build"])
      )

      write_file!(source_file, "defmodule SourceFile do end")
      write_file!(build_file, "defmodule StaleBuildFile do end")

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.new()
      entries = create_index(project)

      FakeBackend.set_entries([%Entry{id: 1, path: build_file} | entries])
      ManifestStore.invalidate(project)

      assert {entry_stream, [^build_file]} = update_index(project)
      refute Enum.any?(entry_stream, &(&1.path == build_file))
    end
  end

  describe "update_index/2 manifest commits" do
    @tag :tmp_dir
    test "keeps the previous manifest if committing a refresh fails", %{tmp_dir: tmp_dir} do
      source_file = native_join([tmp_dir, "lib", "source_file.ex"])
      write_file!(source_file, "defmodule SourceFile do end")

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.bare()

      assert {entries, []} = update_index(project)
      assert [_ | _] = entries
      assert {:ok, old_manifest} = ManifestStore.load(project)

      write_file!(source_file, "defmodule ChangedSourceFile do end")
      File.touch!(source_file, {{2100, 1, 1}, {0, 0, 0}})

      patch(ManifestStore, :commit, fn ^project, _manifest ->
        {:error, :commit_failed}
      end)

      assert {:ok, _entries, [], manifest} =
               Indexer.update_index(project, FakeBackend.path_to_ids())

      assert {:error, :commit_failed} = Indexer.commit_manifest(project, manifest)
      assert {:ok, ^old_manifest} = ManifestStore.load(project)
    end
  end

  describe "update_index/2 encounters a new file" do
    setup [:with_an_existing_index, :with_a_file_with_a_module]

    test "the ephemeral file is not previously present in the index", %{entries: entries} do
      refute Enum.any?(entries, fn entry -> Path.basename(entry.path) == @ephemeral_file_name end)
    end

    test "the ephemeral file is listed in the updated index", %{project: project} do
      assert {entries, []} = update_index(project)
      assert [_structure, updated_entry] = entries

      assert Path.basename(updated_entry.path) == @ephemeral_file_name
      assert updated_entry.subject == Ephemeral
    end

    test "does not write returned entries into the backend", %{project: project} do
      assert {entries, []} = update_index(project)
      assert [_structure, updated_entry] = entries

      refute Enum.any?(FakeBackend.entries(), &(&1.subject == updated_entry.subject))
    end

    test "reindexes a manifest output missing from the backend", %{
      project: project,
      file_path: file_path
    } do
      FakeBackend.set_entries(Enum.reject(FakeBackend.entries(), &(&1.path == file_path)))

      assert {entries, []} = update_index(project)
      assert [_structure, updated_entry] = entries

      assert updated_entry.path == file_path
      assert updated_entry.subject == Ephemeral
    end
  end

  def with_an_ephemeral_empty_file(context) do
    with_an_ephemeral_file(context, "")
  end

  describe "update_index/2 encounters a zero-length file" do
    setup [:with_an_existing_index, :with_an_ephemeral_empty_file]

    test "and does nothing", %{project: project} do
      assert {[], []} = update_index(project)
    end

    test "there is no progress", %{project: project} do
      Dispatch.register_listener(self(), :all)
      assert {[], []} = update_index(project)
      refute_receive _
    end
  end

  describe "update_index/2" do
    setup [:with_a_file_with_a_module, :with_an_existing_index]

    test "sees the ephemeral file", %{entries: entries} do
      assert Enum.any?(entries, fn entry -> Path.basename(entry.path) == @ephemeral_file_name end)
    end

    test "returns the file paths of deleted files", %{project: project, file_path: file_path} do
      File.rm(file_path)

      assert {[], [^file_path]} = update_index(project)
    end

    test "updates files that have changed since the last index", %{
      project: project,
      file_path: file_path
    } do
      new_contents = ~s[
        defmodule Brand.Spanking.New do
        end
      ]

      File.write!(file_path, new_contents)
      File.touch!(file_path, {{2100, 1, 1}, {0, 0, 0}})

      assert {entries, []} = update_index(project)
      assert [_structure, entry] = entries

      assert entry.path == file_path
      assert entry.subject == Brand.Spanking.New
    end

    test "clears files that now index to no entries", %{project: project, file_path: file_path} do
      File.write!(file_path, "")
      File.touch!(file_path, {{2100, 1, 1}, {0, 0, 0}})

      assert {[], [^file_path]} = update_index(project)
    end
  end

  describe "update_index/2 with .exs source entries" do
    @tag :tmp_dir
    test "keeps clean reference entries without reindexing sources", %{tmp_dir: tmp_dir} do
      %{project: project, reference_subject: reference_subject, test_path: test_path} =
        with_test_script_reference_project(tmp_dir)

      entries = create_index(project)
      FakeBackend.set_entries(entries)

      assert Enum.any?(entries, &source_reference?(&1, test_path, reference_subject))

      test_pid = self()

      patch(Sources, :index, fn paths ->
        send(test_pid, {:source_index_paths, paths})
        {[], []}
      end)

      assert {[], []} = update_index(project)
      assert_received {:source_index_paths, []}

      assert Enum.any?(
               FakeBackend.entries(),
               &source_reference?(&1, test_path, reference_subject)
             )
    end
  end

  defp with_test_script_reference_project(tmp_dir) do
    suffix = System.unique_integer([:positive])
    target = Module.concat(SourceReferenceScriptTest, :"Target#{suffix}")
    caller = Module.concat(SourceReferenceScriptTest, :"Caller#{suffix}")
    project_module = Module.concat(SourceReferenceScriptTest, :"MixProject#{suffix}")
    test_path = native_join([tmp_dir, "test", "source_reference_test.exs"])

    write_mix_project!(
      tmp_dir,
      inspect(project_module),
      ~s([app: :source_reference_script_test, version: "0.1.0"])
    )

    write_file!(test_path, """
    defmodule #{inspect(target)} do
      def value, do: :ok
    end

    defmodule #{inspect(caller)} do
      def value, do: #{inspect(target)}.value()
    end
    """)

    %{
      project: tmp_dir |> Forge.Document.Path.to_uri() |> Project.new(),
      reference_subject: Formats.mfa(target, :value, 0),
      test_path: test_path
    }
  end

  defp source_reference?(%Entry{} = entry, path, subject) do
    entry.path == path and entry.subject == subject and entry.type == {:function, :usage} and
      entry.subtype == :reference
  end

  defp with_project_beam(tmp_dir, opts) do
    module = Keyword.fetch!(opts, :module)
    source = Keyword.fetch!(opts, :source)
    app = Keyword.get(opts, :app, :project_beam_indexer_test)
    app_root = native_join([tmp_dir, "project_beam"])
    source_path = native_join([app_root, "lib", "project_beam_module.ex"])

    project_module =
      Module.concat(ProjectBeamIndexerTest, :"MixProject#{System.unique_integer([:positive])}")

    config = [app: app, version: "0.1.0"]

    write_mix_project!(app_root, inspect(project_module), inspect(config))

    Module.create(
      project_module,
      quote do
        def project do
          unquote(Macro.escape(config))
        end
      end,
      Macro.Env.location(__ENV__)
    )

    project =
      app_root
      |> Forge.Document.Path.to_uri()
      |> Project.new()
      |> Project.set_project_module(project_module)

    {:ok, build_path} = Engine.Mix.in_project(project, fn _ -> Mix.Project.build_path() end)
    ebin_path = native_join([build_path, "lib", Atom.to_string(app), "ebin"])

    File.mkdir_p!(Path.dirname(source_path))
    File.mkdir_p!(ebin_path)
    File.write!(source_path, source)

    compiler_options = Code.compiler_options()
    Code.compiler_options(debug_info: true)
    on_exit(fn -> Code.compiler_options(compiler_options) end)

    assert {:ok, [^module], %{compile_warnings: [], runtime_warnings: []}} =
             Kernel.ParallelCompiler.compile_to_path([source_path], ebin_path,
               return_diagnostics: true
             )

    %{
      beam_path: native_join([ebin_path, Atom.to_string(module) <> ".beam"]),
      module: module,
      project: project,
      source_path: source_path
    }
  end

  defp with_beam_dependency(tmp_dir, opts \\ []) do
    module_count = Keyword.get(opts, :module_count, 1)

    modules =
      Keyword.get_lazy(opts, :modules, fn ->
        for _ <- 1..module_count do
          Module.concat(BeamDependencyIndexerTest, :"Dep#{unique_id()}")
        end
      end)

    dep_source = Keyword.get_lazy(opts, :dep_source, fn -> default_dep_source(modules) end)
    dep_source = if is_function(dep_source, 1), do: dep_source.(hd(modules)), else: dep_source

    with_compiled_beam_dependency(tmp_dir, modules, dep_source, opts)
  end

  defp default_dep_source(modules) do
    Enum.map_join(modules, "\n", fn module ->
      """
      defmodule #{inspect(module)} do
        def public_fun, do: private_fun()
        defp private_fun, do: :ok
      end
      """
    end)
  end

  defp with_nested_beam_dependency(tmp_dir) do
    outer = Module.concat(BeamDependencyIndexerTest, :"Outer#{unique_id()}")
    module = Module.concat(outer, Inner)

    dep_source = """
    defmodule #{inspect(outer)} do
      defmodule Inner do
        def public_fun, do: :ok
      end
    end
    """

    with_compiled_beam_dependency(tmp_dir, [outer, module], dep_source,
      module: module,
      rewrite_source?: false
    )
  end

  defp with_protocol_beam_dependency(tmp_dir) do
    protocol = Module.concat(BeamDependencyIndexerTest, :"Protocol#{unique_id()}")

    dep_source = """
    defprotocol #{inspect(protocol)} do
      def run(term)
    end
    """

    with_compiled_beam_dependency(tmp_dir, [protocol], dep_source, module: protocol)
  end

  defp with_protocol_implementation_beam_dependency(tmp_dir, opts \\ []) do
    protocol = Module.concat(BeamDependencyIndexerTest, :"ImplProtocol#{unique_id()}")
    target = Module.concat(BeamDependencyIndexerTest, :"ImplTarget#{unique_id()}")
    impl_module = Module.concat(protocol, target)

    dep_source = """
    defprotocol #{inspect(protocol)} do
      def run(term)
    end

    defmodule #{inspect(target)} do
      defstruct []
    end

    defimpl #{inspect(protocol)}, for: #{inspect(target)} do
      def run(term), do: term
    end
    """

    tmp_dir
    |> with_compiled_beam_dependency(
      [protocol, target, impl_module],
      dep_source,
      Keyword.put(opts, :module, impl_module)
    )
    |> Map.merge(%{impl_module: impl_module, protocol: protocol, target: target})
  end

  defp project_without_beam_dependency(app_root) do
    project_module = Module.concat(BeamDependencyIndexerTest, :"MixProject#{unique_id()}")

    File.write!(Path.join(app_root, "mix.exs"), """
    defmodule #{inspect(project_module)} do
      use Mix.Project

      def project do
        [app: :beam_dependency_indexer_test, version: "0.1.0"]
      end
    end
    """)

    File.touch!(Path.join(app_root, "mix.exs"), {{2000, 1, 1}, {0, 0, 0}})

    Module.create(
      project_module,
      quote do
        def project do
          [app: :beam_dependency_indexer_test, version: "0.1.0"]
        end
      end,
      Macro.Env.location(__ENV__)
    )

    app_root
    |> Forge.Document.Path.to_uri()
    |> Project.new()
    |> Project.set_project_module(project_module)
  end

  defp with_compiled_beam_dependency(tmp_dir, modules, dep_source, opts) do
    app_root = native_join([tmp_dir, "beam_app"])
    module = Keyword.get(opts, :module, hd(modules))

    project_module = Module.concat(BeamDependencyIndexerTest, :"MixProject#{unique_id()}")
    dep_project_module = Module.concat(BeamDependencyIndexerTest, :"DepMixProject#{unique_id()}")
    dep_app = Keyword.get(opts, :dep_app, :beam_dep)
    dep_opts = Keyword.get(opts, :dep_opts, path: "deps/beam_dep")
    dep_tuple = {:beam_dep, dep_opts}

    File.mkdir_p!(app_root)

    File.write!(Path.join(app_root, "mix.exs"), """
    defmodule #{inspect(project_module)} do
      use Mix.Project

      def project do
        [app: :beam_dependency_indexer_test, version: "0.1.0", deps: deps()]
      end

      defp deps do
        #{inspect([dep_tuple])}
      end
    end
    """)

    Module.create(
      project_module,
      quote do
        def project do
          [app: :beam_dependency_indexer_test, version: "0.1.0", deps: deps()]
        end

        defp deps do
          unquote(Macro.escape([dep_tuple]))
        end
      end,
      Macro.Env.location(__ENV__)
    )

    project =
      app_root
      |> Forge.Document.Path.to_uri()
      |> Project.new()
      |> Project.set_project_module(project_module)

    {:ok, deps_root} = Engine.Mix.in_project(project, fn _ -> Mix.Project.deps_path() end)
    {:ok, build_path} = Engine.Mix.in_project(project, fn _ -> Mix.Project.build_path() end)
    dep_root = native_join([deps_root, "beam_dep"])
    dep_file = native_join([dep_root, "lib", "beam_dep_module.ex"])
    ebin_path = native_join([build_path, "lib", Atom.to_string(dep_app), "ebin"])

    File.mkdir_p!(Path.dirname(dep_file))
    File.mkdir_p!(ebin_path)

    File.write!(Path.join(dep_root, "mix.exs"), """
    defmodule #{inspect(dep_project_module)} do
      use Mix.Project

      def project do
        [app: #{inspect(dep_app)}, version: "0.1.0"]
      end
    end
    """)

    File.write!(dep_file, dep_source)

    compiler_options = Code.compiler_options()
    Code.compiler_options(debug_info: Keyword.get(opts, :debug_info?, true))
    on_exit(fn -> Code.compiler_options(compiler_options) end)

    compiled_modules = compile_to_path!([dep_file], ebin_path)
    expected_modules = Keyword.get(opts, :expected_modules, modules)

    assert Enum.sort(compiled_modules) == Enum.sort(expected_modules)

    if Keyword.get(opts, :rewrite_source?, true) do
      File.write!(dep_file, "defmodule")
      File.touch!(dep_file, {{2000, 1, 1}, {0, 0, 0}})
    end

    beam_paths = Enum.map(modules, &native_join([ebin_path, Atom.to_string(&1) <> ".beam"]))

    %{
      app_root: app_root,
      beam_path: hd(beam_paths),
      beam_paths: beam_paths,
      compiled_modules: compiled_modules,
      dep_file: dep_file,
      module: module,
      modules: modules,
      project: project
    }
  end

  defp with_transitive_beam_dependency(tmp_dir) do
    app_root = Path.join(tmp_dir, "beam_app")
    suffix = unique_id()
    direct_dep_app = :"beam_dep_#{suffix}"
    transitive_dep_app = :"transitive_dep_#{suffix}"
    direct_dep_path = "deps/#{direct_dep_app}"
    module = Module.concat(BeamDependencyIndexerTest, :"TransitiveDep#{suffix}")

    project_module = Module.concat(BeamDependencyIndexerTest, :"TransitiveMixProject#{suffix}")

    direct_dep_project_module =
      Module.concat(BeamDependencyIndexerTest, :"DirectDepMixProject#{suffix}")

    transitive_dep_project_module =
      Module.concat(BeamDependencyIndexerTest, :"TransitiveDepMixProject#{suffix}")

    File.mkdir_p!(app_root)

    File.write!(Path.join(app_root, "mix.exs"), """
    defmodule #{inspect(project_module)} do
      use Mix.Project

      def project do
        [app: :beam_dependency_indexer_test, version: "0.1.0", deps: deps()]
      end

      defp deps do
        [{#{inspect(direct_dep_app)}, path: #{inspect(direct_dep_path)}}]
      end
    end
    """)

    Module.create(
      project_module,
      quote do
        def project do
          [app: :beam_dependency_indexer_test, version: "0.1.0", deps: deps()]
        end

        defp deps do
          [{unquote(direct_dep_app), path: unquote(direct_dep_path)}]
        end
      end,
      Macro.Env.location(__ENV__)
    )

    project =
      app_root
      |> Forge.Document.Path.to_uri()
      |> Project.new()
      |> Project.set_project_module(project_module)

    {:ok, deps_root} = Engine.Mix.in_project(project, fn _ -> Mix.Project.deps_path() end)
    {:ok, build_path} = Engine.Mix.in_project(project, fn _ -> Mix.Project.build_path() end)

    direct_dep_root = Path.join(deps_root, Atom.to_string(direct_dep_app))
    transitive_dep_root = Path.join(deps_root, Atom.to_string(transitive_dep_app))
    transitive_file = Path.join([transitive_dep_root, "lib", "transitive_dep_module.ex"])
    ebin_path = Path.join([build_path, "lib", Atom.to_string(transitive_dep_app), "ebin"])

    File.mkdir_p!(direct_dep_root)
    File.mkdir_p!(Path.dirname(transitive_file))
    File.mkdir_p!(ebin_path)

    File.write!(Path.join(direct_dep_root, "mix.exs"), """
    defmodule #{inspect(direct_dep_project_module)} do
      use Mix.Project

      def project do
        [app: #{inspect(direct_dep_app)}, version: "0.1.0", deps: deps()]
      end

      defp deps do
        [{#{inspect(transitive_dep_app)}, path: "../#{transitive_dep_app}"}]
      end
    end
    """)

    File.write!(Path.join(transitive_dep_root, "mix.exs"), """
    defmodule #{inspect(transitive_dep_project_module)} do
      use Mix.Project

      def project do
        [app: #{inspect(transitive_dep_app)}, version: "0.1.0"]
      end
    end
    """)

    File.write!(transitive_file, """
    defmodule #{inspect(module)} do
      def public_fun, do: :ok
    end
    """)

    compiler_options = Code.compiler_options()
    Code.compiler_options(debug_info: true)
    on_exit(fn -> Code.compiler_options(compiler_options) end)

    assert [^module] = compile_to_path!([transitive_file], ebin_path)

    %{module: module, project: project}
  end

  defp compile_to_path!(files, ebin_path) do
    assert {:ok, compiled_modules, %{compile_warnings: [], runtime_warnings: []}} =
             Kernel.ParallelCompiler.compile_to_path(files, ebin_path, return_diagnostics: true)

    compiled_modules
  end

  defp expected_column(path, text) do
    line = line_containing(path, text)
    {byte_index, _length} = :binary.match(line, text)

    line
    |> binary_part(0, byte_index)
    |> String.length()
    |> Kernel.+(1)
  end

  defp line_containing(path, text) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.find(&String.contains?(&1, text))
  end

  defp unique_id do
    System.unique_integer([:positive])
  end

  defp native_join(path_segments) do
    path_segments
    |> Path.join()
    |> Forge.Path.native()
  end
end
