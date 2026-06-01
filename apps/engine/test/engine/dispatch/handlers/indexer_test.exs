defmodule Engine.Dispatch.Handlers.IndexingTest do
  use ExUnit.Case
  use Patch

  import Forge.EngineApi.Messages
  import Forge.Test.CodeSigil
  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Engine.Commands
  alias Engine.Compilation.TraceBuffer
  alias Engine.Dispatch.Handlers.Indexing
  alias Engine.Search.Indexer.Manifest
  alias Engine.Search.Indexer.ManifestStore
  alias Engine.Search.Indexer.Source
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Indexer.Source.Block

  setup do
    project = project()
    Engine.set_project(project)
    {:ok, store} = Agent.start_link(fn -> %{} end)

    # Mock the broadcast so progress reporting doesn't fail
    patch(Engine.Api.Proxy, :broadcast, fn _ -> :ok end)
    # Mock erpc calls for progress reporting
    patch(Engine.Dispatch, :erpc_call, fn
      Expert.Progress, :begin, [_title, _opts] ->
        {:ok, System.unique_integer([:positive])}

      Expert.Progress, :report, _args ->
        :ok
    end)

    patch(Engine.ManagerApi, :search_store_clear, fn ^project, path ->
      clear_store(store, path)
    end)

    patch(Engine.ManagerApi, :search_store_update, fn ^project, path, entries ->
      update_store(store, path, entries)
    end)

    patch(Engine.ManagerApi, :search_store_exact, fn ^project, subject, _constraints ->
      {:ok, exact_entries(store, subject)}
    end)

    patch(Engine.Dispatch, :erpc_cast, fn Expert.Progress, _function, _args -> true end)

    start_supervised!(Engine.ApplicationCache)
    start_supervised!(TraceBuffer)
    start_supervised!(Engine.Dispatch)
    start_supervised!({Commands.Reindex, debounce_interval_millis: 0})
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})

    {:ok, state} = Indexing.init([])
    {:ok, state: state, project: project, store: store}
  end

  defp update_store(store, path, entries) do
    Agent.update(store, &Map.put(&1, path, entries))
    :ok
  end

  defp clear_store(store, path) do
    Agent.update(store, fn entries_by_path ->
      Map.reject(entries_by_path, fn {stored_path, entries} ->
        stored_path == path or Enum.any?(entries, &(&1.path == path))
      end)
    end)

    :ok
  end

  defp exact_entries(store, subject) do
    store
    |> Agent.get(& &1)
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(
      &(&1.type == :module and format_subject(&1.subject) == format_subject(subject))
    )
  end

  defp exact(store, subject) do
    {:ok, exact_entries(store, subject)}
  end

  def set_document!(source) do
    uri = "file:///file.ex"

    :ok =
      case Document.Store.fetch(uri) do
        {:ok, _} ->
          Document.Store.update(uri, fn doc ->
            edit = Document.Edit.new(source)
            Document.apply_content_changes(doc, doc.version + 1, [edit])
          end)

        {:error, :not_open} ->
          Document.Store.open(uri, source, 1)
      end

    {uri, source}
  end

  defp format_subject(subject) when is_atom(subject), do: Forge.Formats.module(subject)
  defp format_subject(subject) when is_binary(subject), do: subject
  defp format_subject(subject), do: to_string(subject)

  describe "handling file_quoted events" do
    test "does not commit staged trace entries", %{state: state, store: store} do
      {uri, _source} =
        ~q[
          defmodule NewModule do
          end
        ]
        |> set_document!()

      stage_module_definition(uri, NewModule)
      assert {:ok, _} = Indexing.on_event(file_compiled(uri: uri, status: :success), state)

      assert {:ok, []} = exact(store, "NewModule")
      assert TraceBuffer.traced?(Document.Path.ensure_path(uri))
    end

    test "does not replace source-indexed entries with staged trace entries", %{
      state: state,
      store: store
    } do
      {uri, source} =
        ~q[
          defmodule OldModule do
          end
        ]
        |> set_document!()

      {:ok, entries} = Source.index(uri, source)
      update_store(store, uri, entries)
      assert_eventually({:ok, [_entry]} = exact(store, "OldModule"))

      {^uri, _source} =
        ~q[
          defmodule UpdatedModule do
          end
        ]
        |> set_document!()

      stage_module_definition(uri, UpdatedModule)
      assert {:ok, _} = Indexing.on_event(file_compiled(uri: uri, status: :success), state)

      assert {:ok, []} = exact(store, "UpdatedModule")
      assert {:ok, [_entry]} = exact(store, "OldModule")
      assert TraceBuffer.traced?(Document.Path.ensure_path(uri))
    end

    test "does not clear source-indexed entries for untraced successful compiles", %{
      state: state,
      store: store
    } do
      {uri, source} =
        ~q[
          defmodule SourceIndexed do
          end
        ]
        |> set_document!()

      {:ok, entries} = Source.index(uri, source)
      update_store(store, uri, entries)

      assert_eventually({:ok, [_entry]} = exact(store, "SourceIndexed"))

      assert {:ok, _} = Indexing.on_event(file_compiled(uri: uri, status: :success), state)

      assert_eventually({:ok, [_entry]} = exact(store, "SourceIndexed"))
    end

    @tag :tmp_dir
    test "does not commit traced file compiles as dirty source manifest entries", %{
      project: project,
      state: state,
      tmp_dir: tmp_dir
    } do
      source_path = Path.join(tmp_dir, "dirty_source.ex")
      beam_path = Path.join(tmp_dir, "Elixir.LiveSource.beam")
      uri = Document.Path.to_uri(source_path)

      File.write!(source_path, "defmodule LiveSource do end")
      File.write!(beam_path, "beam")

      assert {:ok, beam_entry} = Manifest.Entry.beam(beam_path, source_path)
      assert :ok = ManifestStore.commit(project, Manifest.new([beam_entry]))

      stage_module_definition(uri, LiveSource)

      assert {:ok, _} =
               Indexing.on_event(
                 file_compiled(project: project, uri: uri, status: :success),
                 state
               )

      assert {:ok, manifest} = ManifestStore.load(project)

      assert [^beam_entry] = Manifest.entries(manifest)
      assert TraceBuffer.traced?(source_path)
    end

    test "only updates entries if the version of the document is the same as the version in the document store",
         %{state: state, store: store} do
      Document.Store.open("file:///file.ex", "defmodule Newer do \nend", 3)

      {uri, _source} =
        ~q[
          defmodule Stale do
          end
        ]
        |> set_document!()

      assert {:ok, _} = Indexing.on_event(file_compile_requested(uri: uri), state)
      assert {:ok, []} = exact(store, "Stale")
    end
  end

  describe "a file is deleted" do
    test "its entries should be deleted", %{project: project, state: state, store: store} do
      {uri, source} =
        ~q[
          defmodule ToDelete do
          end
        ]
        |> set_document!()

      {:ok, entries} = Source.index(uri, source)
      update_store(store, uri, entries)

      assert_eventually({:ok, [_]} = exact(store, "ToDelete"))

      Indexing.on_event(
        filesystem_event(project: project, uri: uri, event_type: :deleted),
        state
      )

      assert_eventually({:ok, []} = exact(store, "ToDelete"))
    end
  end

  describe "a file is created" do
    test "is a no op", %{project: project, state: state, store: store} do
      spy(Engine.Search.Indexer)

      event = filesystem_event(project: project, uri: "file:///another.ex", event_type: :created)

      assert {:ok, _} = Indexing.on_event(event, state)

      assert Agent.get(store, & &1) == %{}
      assert history(Engine.Search.Indexer) == []
    end
  end

  defp stage_module_definition(uri, module) do
    path = Document.Path.ensure_path(uri)

    TraceBuffer.add_definitions(path, module, [module_definition(path, module)])
  end

  defp module_definition(path, module) do
    Entry.definition(
      path,
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
end
