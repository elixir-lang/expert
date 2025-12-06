defmodule Engine.Api.ProxyTest do
  alias Engine.Api.Proxy
  alias Engine.Api.Proxy.BufferingState
  alias Engine.Api.Proxy.DrainingState
  alias Engine.Build
  alias Engine.CodeMod
  alias Engine.Commands
  alias Engine.Dispatch

  alias Forge.Document
  alias Forge.Document.Changes

  use ExUnit.Case
  use Patch

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  setup do
    start_supervised!(Proxy)
    project = project()
    Engine.set_project(project)

    {:ok, project: project}
  end

  describe "proxy mode" do
    test "proxies broadcasts" do
      patch(Dispatch, :broadcast, :ok)
      assert :ok = Proxy.broadcast(:hello)

      assert_called(Dispatch.broadcast(:hello))
    end

    test "proxies broadcasts of progress messages" do
      patch(Dispatch, :broadcast, :ok)
      progress_message = {:engine_progress_report, 123, [message: "testing"]}
      assert :ok = Proxy.broadcast(progress_message)

      assert_called(Dispatch.broadcast(^progress_message))
    end

    test "schedule compile is proxied", %{project: project} do
      patch(Build, :schedule_compile, :ok)
      assert :ok = Proxy.schedule_compile(true)
      assert_called(Build.schedule_compile(^project, true))

      assert :ok = Proxy.schedule_compile()
      assert_called(Build.schedule_compile(^project, false))
    end

    test "compile document is proxied", %{project: project} do
      document = %Document{}
      patch(Build, :compile_document, :ok)

      assert :ok = Proxy.compile_document(document)
      assert_called(Build.compile_document(^project, ^document))
    end

    test "reindex is proxied" do
      patch(Commands.Reindex, :perform, :ok)
      patch(Commands.Reindex, :running?, false)

      refute Proxy.index_running?()
      assert :ok = Proxy.reindex()
      assert_called(Commands.Reindex.perform())
      assert_called(Commands.Reindex.running?())
    end

    test "formatting is proxied" do
      document = %Document{}
      patch(CodeMod.Format, :edits, {:ok, Changes.new(document, [])})

      assert {:ok, %Changes{}} = Proxy.format(document)
      assert_called(CodeMod.Format.edits(^document))
    end
  end

  def with_draining_mode(ctx) do
    patch(Commands.Reindex, :perform, fn ->
      Process.sleep(100)
      :ok
    end)

    me = self()

    spawn_link(fn ->
      send(me, :ready)
      result = Proxy.reindex()
      send(me, {:proxy_result, result})
    end)

    assert_receive :ready
    Process.sleep(50)

    with_buffer_mode(ctx)
  end

  describe "draining mode" do
    setup [:with_draining_mode]

    test "handles in-flight calls" do
      assert {:draining, %DrainingState{}} = :sys.get_state(Proxy)
      assert_receive {:proxy_result, :ok}
      assert {:buffering, %BufferingState{}} = :sys.get_state(Proxy)
    end

    test "buffers subsequent calls" do
      me = self()
      patch(Dispatch, :broadcast, fn message -> send(me, {:broadcast, message}) end)
      assert :ok = Proxy.broadcast(:hello)
      assert :ok = Proxy.broadcast(:goodbye)

      refute_receive {:broadcast, _}
    end

    test "ends when in-flight requests end", %{stop_buffering: stop_buffering} do
      patch(Build, :schedule_compile, callable(fn _ -> :ok end))

      assert :ok = Proxy.schedule_compile()
      refute_called(Build.schedule_compile(_, _))
      assert_receive {:proxy_result, :ok}
      stop_buffering.()
      assert_called(Build.schedule_compile(_, _))
    end
  end

  def with_buffer_mode(_) do
    buffer_proc =
      spawn_link(fn ->
        receive do
          :continue ->
            :ok
        end
      end)

    Proxy.start_buffering(buffer_proc)

    stop_buffering = fn ->
      send(buffer_proc, :continue)
      Process.sleep(50)
    end

    {:ok, stop_buffering: stop_buffering}
  end

  describe "buffer mode" do
    setup [:with_buffer_mode]

    test "start_buffering can't be called twice" do
      assert {:error, {:already_buffering, _}} = Proxy.start_buffering()
    end

    test "proxies broadcasts of progress messages" do
      patch(Dispatch, :broadcast, :ok)
      progress_message = {:engine_progress_begin, 123, "test", []}
      assert :ok = Proxy.broadcast(progress_message)

      assert_called(Dispatch.broadcast(^progress_message))
    end

    test "buffers broadcasts" do
      assert :ok = Proxy.broadcast(file_compile_requested())
      refute_any_call(Dispatch.broadcast())
    end

    test "buffers schedule compile" do
      patch(Build, :schedule_compile, :ok)
      assert :ok = Proxy.schedule_compile(true)
      refute_any_call(Build.schedule_compile())

      assert :ok = Proxy.schedule_compile()
      refute_any_call(Build.schedule_compile())
    end

    test "buffers compile document" do
      document = %Document{}
      patch(Build, :compile_document, :ok)

      assert :ok = Proxy.compile_document(document)
      refute_any_call(Build.compile_document())
    end

    test "buffers reindex" do
      patch(Commands.Reindex, :perform, :ok)
      patch(Commands.Reindex, :running?, false)

      refute Proxy.index_running?()
      assert :ok = Proxy.reindex()
      refute_any_call(Commands.Reindex.perform())
      refute_any_call(Commands.Reindex.running?())
    end

    test "buffers formatting" do
      document = %Document{}
      patch(CodeMod.Format, :edits, {:ok, Changes.new(document, [])})

      assert {:ok, %Changes{}} = Proxy.format(document)
      refute_any_call(CodeMod.Format.edits())
    end
  end

  describe "flushing after buffered mode" do
    setup [:with_buffer_mode]

    test "buffered messages are sent", %{stop_buffering: stop_buffering} do
      patch(Dispatch, :broadcast, :ok)

      Proxy.broadcast(module_updated())
      Proxy.broadcast(project_diagnostics())

      refute_any_call(Dispatch.broadcast())
      stop_buffering.()

      assert_called(Dispatch.broadcast(module_updated()))
      assert_called(Dispatch.broadcast(project_diagnostics()))
    end

    test "formats are dropped", %{stop_buffering: stop_buffering} do
      document = %Document{}
      patch(CodeMod.Format, :edits, {:ok, Changes.new(document, [])})

      Proxy.format(document)
      stop_buffering.()
      refute_any_call(CodeMod.Format.edits())
    end

    test "a single compile is scheduled", %{project: project, stop_buffering: stop_buffering} do
      patch(Build, :schedule_compile, :ok)

      Proxy.schedule_compile()
      Proxy.schedule_compile()

      refute_any_call(Build.schedule_compile())

      stop_buffering.()

      assert_called(Build.schedule_compile(^project, _), 1)
    end

    test "document compilations are buffered", %{project: project, stop_buffering: stop_buffering} do
      doc = %Document{}
      patch(Document.Store, :open?, true)
      patch(Build, :compile_document, :ok)

      Proxy.compile_document(doc)
      Proxy.compile_document(doc)

      refute_any_call(Build.compile_document())

      stop_buffering.()

      assert_called(Build.compile_document(^project, ^doc), 1)
    end

    test "reindex calls are buffered", %{stop_buffering: stop_buffering} do
      patch(Commands.Reindex, :perform, :ok)

      Proxy.reindex()
      Proxy.reindex()
      Proxy.reindex()

      refute_any_call(Commands.Reindex.perform())

      stop_buffering.()

      assert_called(Commands.Reindex.perform())
    end

    test "calls to Reindex.running?() are dropped", %{stop_buffering: stop_buffering} do
      patch(Commands.Reindex, :running?, false)

      Proxy.index_running?()
      Proxy.index_running?()
      Proxy.index_running?()

      refute_any_call(Commands.Reindex.running?())

      stop_buffering.()

      refute_any_call(Commands.Reindex.running?())
    end
  end
end
