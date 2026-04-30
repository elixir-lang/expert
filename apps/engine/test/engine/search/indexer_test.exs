defmodule Engine.Search.IndexerTest do
  use ExUnit.Case
  use Patch

  import Forge.Test.Fixtures

  alias Engine.Dispatch
  alias Engine.Search.Indexer
  alias Engine.Search.Indexer.Manifest
  alias Engine.Search.Indexer.Manifest.Entry, as: ManifestEntry
  alias Engine.Search.Indexer.ManifestStore
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  defmodule FakeBackend do
    @behaviour Engine.Search.Store.Backend

    def new(_project), do: {:ok, :new}

    def prepare(_backend_result) do
      if entries() == [] do
        {:ok, :empty}
      else
        {:ok, :stale}
      end
    end

    def set_entries(entries) when is_list(entries) do
      :persistent_term.put({__MODULE__, :entries}, entries)
    end

    def entries do
      :persistent_term.get({__MODULE__, :entries}, [])
    end

    def replace_all(entries) when is_list(entries) do
      set_entries(entries)
      :ok
    end

    def delete_by_path(path) do
      {deleted_entries, kept_entries} =
        {__MODULE__, :entries}
        |> :persistent_term.get([])
        |> Enum.split_with(&(&1.path == path))

      set_entries(kept_entries)

      {:ok, Enum.flat_map(deleted_entries, &List.wrap(&1.id))}
    end

    def insert(entries) when is_list(entries) do
      current_entries = :persistent_term.get({__MODULE__, :entries}, [])
      set_entries(current_entries ++ entries)
      :ok
    end

    def reduce(accumulator, reducer_fun) do
      {__MODULE__, :entries}
      |> :persistent_term.get([])
      |> Enum.reduce(accumulator, fn
        %Entry{} = entry, acc -> reducer_fun.(entry, acc)
        _, acc -> acc
      end)
    end

    def find_by_subject(_subject, _type, _subtype), do: []
    def find_by_prefix(_prefix, _type, _subtype), do: []
    def find_by_ids(_ids, _type, _subtype), do: []
    def siblings(_entry), do: []
    def parent(_entry), do: nil
    def structure_for_path(_path), do: :error
    def drop, do: set_entries([])
    def destroy(_project), do: :ok
  end

  setup do
    project = project()
    start_supervised!(Engine.ApplicationCache)
    start_supervised(Dispatch)
    # Mock the broadcast so progress reporting doesn't fail
    patch(Engine.Api.Proxy, :broadcast, fn _ -> :ok end)
    # Mock erpc calls for progress reporting
    patch(Dispatch, :erpc_call, fn
      Expert.Progress, :begin, [_title, _opts] ->
        {:ok, System.unique_integer([:positive])}

      Expert.Progress, :report, _args ->
        :ok
    end)

    patch(Dispatch, :erpc_cast, fn Expert.Progress, _function, _args -> true end)
    FakeBackend.set_entries([])
    ManifestStore.invalidate(project)
    {:ok, project: project}
  end

  defp create_index(project) do
    assert :ok = Indexer.create_index(project, FakeBackend)
    FakeBackend.entries()
  end

  defp update_index(project, backend \\ FakeBackend) do
    before_entries = backend.entries()

    assert :ok = Indexer.update_index(project, backend)

    after_entries = backend.entries()

    {changed_entries(before_entries, after_entries), deleted_paths(before_entries, after_entries)}
  end

  defp changed_entries(before_entries, after_entries) do
    before_by_path = entries_by_path(before_entries)

    after_entries
    |> entries_by_path()
    |> Enum.flat_map(fn {path, entries} ->
      if Map.get(before_by_path, path, []) == entries do
        []
      else
        entries
      end
    end)
  end

  defp deleted_paths(before_entries, after_entries) do
    before_paths = before_entries |> entries_by_path() |> Map.keys() |> MapSet.new()
    after_paths = after_entries |> entries_by_path() |> Map.keys() |> MapSet.new()

    before_paths
    |> MapSet.difference(after_paths)
    |> Enum.to_list()
  end

  defp entries_by_path(entries) do
    entries
    |> Enum.reject(&is_nil(&1.path))
    |> Enum.group_by(& &1.path)
  end

  defp write_file!(path, contents) do
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

    Path.join([build_root | List.wrap(relative_path)])
  end

  describe "create_index/2" do
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
      bare_root = Path.join(fixtures_path(), "scratch")
      bare_project = bare_root |> Forge.Document.Path.to_uri() |> Project.bare()

      patch(Engine, :get_project, fn -> bare_project end)

      entries = create_index(bare_project)
      assert Enum.any?(entries, &(&1.path == Path.join(bare_root, "bare_file.ex")))
    end

    @tag :tmp_dir
    test "indexes active path dependency beams", %{tmp_dir: tmp_dir} do
      %{module: module, project: project} = with_beam_dependency(tmp_dir)

      entries = create_index(project)
      entries = Enum.to_list(entries)

      assert Enum.any?(entries, &(&1.subject == module and &1.subtype == :definition))
    end

    @tag :tmp_dir
    test "does not index dependency beams when the dependency has app false", %{tmp_dir: tmp_dir} do
      %{module: module, project: project} =
        with_beam_dependency(tmp_dir, dep_opts: [path: "deps/beam_dep", app: false])

      entries = create_index(project)
      entries = Enum.to_list(entries)

      refute Enum.any?(entries, &(&1.subject == module and &1.subtype == :definition))
    end

    @tag :tmp_dir
    test "caches dependency beams with no debug metadata", %{tmp_dir: tmp_dir} do
      %{beam_path: beam_path, module: module, project: project} =
        with_beam_dependency(tmp_dir, debug_info?: false, rewrite_source?: false)

      assert {entries, []} = update_index(project)
      entries = Enum.to_list(entries)
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
      entries = Enum.to_list(entries)
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
      FakeBackend.set_entries(Enum.to_list(entries))
      assert {:ok, manifest} = ManifestStore.load(project)

      old_manifest_entries =
        manifest
        |> Manifest.entries()
        |> Enum.reject(&(&1.input_path == beam_path))

      assert :ok =
               ManifestStore.commit(project, Manifest.new(old_manifest_entries))

      test_pid = self()

      patch(Dispatch, :erpc_call, fn
        Expert.Progress, :begin, ["Indexing dependencies metadata", _opts] ->
          send(test_pid, :dependency_progress_begin)
          {:ok, System.unique_integer([:positive])}

        Expert.Progress, :begin, [_title, _opts] ->
          {:ok, System.unique_integer([:positive])}

        Expert.Progress, :report, _args ->
          :ok
      end)

      assert {entries, []} = update_index(project)
      assert [] = Enum.to_list(entries)
      assert_receive :dependency_progress_begin
      refute_receive :dependency_progress_begin, 0

      assert {entries, []} = update_index(project)
      assert [] = Enum.to_list(entries)
      refute_receive :dependency_progress_begin
    end
  end

  @ephemeral_file_name "ephemeral.ex"

  def with_an_ephemeral_file(%{project: project}, file_contents) do
    file_path = Path.join([Project.root_path(project), "lib", @ephemeral_file_name])
    File.write!(file_path, file_contents)

    on_exit(fn ->
      File.rm(file_path)
    end)

    {:ok, file_path: file_path}
  end

  def with_a_file_with_a_module(context) do
    file_contents = ~s[
        defmodule Ephemeral do
        end
      ]
    with_an_ephemeral_file(context, file_contents)
  end

  def with_an_existing_index(%{project: project}) do
    {entries, []} = update_index(project)
    entries = Enum.to_list(entries)
    FakeBackend.set_entries(entries)

    {:ok, entries: entries}
  end

  describe "update_index/2 removes paths that became non-indexable" do
    @tag :tmp_dir
    test "deletes previously indexed configured build files even when they still exist", %{
      tmp_dir: tmp_dir
    } do
      source_file = Path.join([tmp_dir, "lib", "source_file.ex"])
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
      entries = Enum.to_list(entries)

      FakeBackend.set_entries([%Entry{id: 1, path: build_file} | entries])
      ManifestStore.invalidate(project)

      assert {entry_stream, [^build_file]} = update_index(project)
      refute Enum.any?(entry_stream, &(&1.path == build_file))
    end
  end

  describe "update_index/2 manifest commits" do
    @tag :tmp_dir
    test "keeps the previous manifest if committing a refresh fails", %{tmp_dir: tmp_dir} do
      source_file = Path.join([tmp_dir, "lib", "source_file.ex"])
      write_file!(source_file, "defmodule SourceFile do end")

      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.bare()

      assert {entries, []} = update_index(project)
      assert [_ | _] = Enum.to_list(entries)
      assert {:ok, old_manifest} = ManifestStore.load(project)

      write_file!(source_file, "defmodule ChangedSourceFile do end")
      File.touch!(source_file, {{2100, 1, 1}, {0, 0, 0}})

      patch(ManifestStore, :commit, fn ^project, _manifest ->
        {:error, :commit_failed}
      end)

      assert {:error, :commit_failed} = Indexer.update_index(project, FakeBackend)
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
      assert [_structure, updated_entry] = Enum.to_list(entries)

      assert Path.basename(updated_entry.path) == @ephemeral_file_name
      assert updated_entry.subject == Ephemeral
    end

    test "writes updated entries into the backend", %{project: project} do
      assert {entries, []} = update_index(project)
      assert [_structure, updated_entry] = Enum.to_list(entries)

      assert Enum.any?(FakeBackend.entries(), &(&1.subject == updated_entry.subject))
    end

    test "reindexes a manifest output missing from the backend", %{
      project: project,
      file_path: file_path
    } do
      FakeBackend.set_entries(Enum.reject(FakeBackend.entries(), &(&1.path == file_path)))

      assert {entries, []} = update_index(project)
      assert [_structure, updated_entry] = Enum.to_list(entries)

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
      assert {entries, []} = update_index(project)
      assert [] = Enum.to_list(entries)
    end

    test "there is no progress", %{project: project} do
      # this ensures we don't emit progress with a total byte size of 0, which will
      # cause an ArithmeticError

      Dispatch.register_listener(self(), :all)
      assert {entries, []} = update_index(project)
      assert [] = Enum.to_list(entries)
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

      assert {entries, [^file_path]} = update_index(project)
      assert [] = Enum.to_list(entries)
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
      assert [_structure, entry] = Enum.to_list(entries)

      assert entry.path == file_path
      assert entry.subject == Brand.Spanking.New
    end

    test "clears files that now index to no entries", %{
      project: project,
      file_path: file_path
    } do
      File.write!(file_path, "")
      File.touch!(file_path, {{2100, 1, 1}, {0, 0, 0}})

      assert {entries, [^file_path]} = update_index(project)
      assert [] = Enum.to_list(entries)
    end
  end

  defp with_beam_dependency(tmp_dir, opts \\ []) do
    module =
      Keyword.get_lazy(opts, :module, fn ->
        Module.concat(BeamDependencyIndexerTest, :"Dep#{System.unique_integer([:positive])}")
      end)

    dep_source =
      case Keyword.get(opts, :dep_source) do
        nil ->
          """
          defmodule #{inspect(module)} do
            def public_fun, do: private_fun()
            defp private_fun, do: :ok
          end
          """

        source when is_binary(source) ->
          source

        source_fun when is_function(source_fun, 1) ->
          source_fun.(module)
      end

    app_root = Path.join(tmp_dir, "beam_app")

    project_module =
      Module.concat(BeamDependencyIndexerTest, :"MixProject#{System.unique_integer([:positive])}")

    dep_project_module =
      Module.concat(
        BeamDependencyIndexerTest,
        :"DepMixProject#{System.unique_integer([:positive])}"
      )

    dep_app = Keyword.get(opts, :dep_app, :beam_dep)
    dep_opts = Keyword.get(opts, :dep_opts, path: "deps/beam_dep")
    dep_tuple = {:beam_dep, dep_opts}

    File.mkdir_p!(app_root)
    mix_exs_path = Path.join(app_root, "mix.exs")

    File.write!(mix_exs_path, """
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
    dep_root = Path.join(deps_root, "beam_dep")
    dep_file = Path.join([dep_root, "lib", "beam_dep_module.ex"])
    ebin_path = Path.join([build_path, "lib", Atom.to_string(dep_app), "ebin"])

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

    assert {:ok, compiled_modules, %{compile_warnings: [], runtime_warnings: []}} =
             Kernel.ParallelCompiler.compile_to_path([dep_file], ebin_path,
               return_diagnostics: true
             )

    expected_modules = Keyword.get(opts, :expected_modules, [module])

    assert Enum.sort(compiled_modules) == Enum.sort(expected_modules)

    if Keyword.get(opts, :rewrite_source?, true) do
      File.write!(dep_file, "defmodule")
      File.touch!(dep_file, {{2000, 1, 1}, {0, 0, 0}})
    end

    %{
      beam_path: Path.join(ebin_path, Atom.to_string(module) <> ".beam"),
      beam_paths:
        Enum.map(compiled_modules, &Path.join(ebin_path, Atom.to_string(&1) <> ".beam")),
      compiled_modules: compiled_modules,
      dep_file: dep_file,
      module: module,
      project: project
    }
  end
end
