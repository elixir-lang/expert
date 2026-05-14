defmodule Engine.Dispatch.Handlers.IndexingTest do
  use ExUnit.Case
  use Patch

  import Forge.EngineApi.Messages
  import Forge.Test.CodeSigil
  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Engine.Commands
  alias Engine.Dispatch.Handlers.Indexing
  alias Engine.Search
  alias Forge.Document

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
    test "should add new entries to the store", %{state: state, store: store} do
      {uri, _source} =
        ~q[
          defmodule NewModule do
          end
        ]
        |> set_document!()

      assert {:ok, _} = Indexing.on_event(file_compile_requested(uri: uri), state)

      assert_eventually {:ok, [entry]} = exact(store, "NewModule")

      assert entry.subject == NewModule
    end

    test "should update entries in the store", %{state: state, store: store} do
      {uri, source} =
        ~q[
          defmodule OldModule
          end
        ]
        |> set_document!()

      {:ok, _} = Search.Indexer.Source.index(uri, source)

      {^uri, _source} =
        ~q[
          defmodule UpdatedModule do
          end
        ]
        |> set_document!()

      assert {:ok, _} = Indexing.on_event(file_compile_requested(uri: uri), state)

      assert_eventually {:ok, [entry]} = exact(store, "UpdatedModule")
      assert entry.subject == UpdatedModule
      assert {:ok, []} = exact(store, "OldModule")
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

      {:ok, entries} = Search.Indexer.Source.index(uri, source)
      update_store(store, uri, entries)

      assert_eventually {:ok, [_]} = exact(store, "ToDelete")

      Indexing.on_event(
        filesystem_event(project: project, uri: uri, event_type: :deleted),
        state
      )

      assert_eventually {:ok, []} = exact(store, "ToDelete")
    end
  end

  describe "a file is created" do
    test "is a no op", %{project: project, state: state, store: store} do
      spy(Search.Indexer)

      event = filesystem_event(project: project, uri: "file:///another.ex", event_type: :created)

      assert {:ok, _} = Indexing.on_event(event, state)

      assert Agent.get(store, & &1) == %{}
      assert history(Search.Indexer) == []
    end
  end
end
