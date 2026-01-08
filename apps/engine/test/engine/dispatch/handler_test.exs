defmodule Engine.Dispatch.HandlerTest do
  alias Engine.Dispatch
  alias Forge.EngineApi.Messages

  import Messages
  use ExUnit.Case

  setup do
    start_supervised!(Dispatch)
    :ok
  end

  defmodule AllForwarder do
    use Dispatch.Handler, :all

    def on_event(event, caller_pid) do
      send(caller_pid, {__MODULE__, event})
      {:ok, caller_pid}
    end
  end

  describe "All forwarder" do
    setup do
      Dispatch.add_handler(AllForwarder, self())
      :ok
    end

    test "sends all messages here" do
      file_changed = file_changed(uri: "file:////foo/bar.ex")
      Dispatch.broadcast(file_changed)
      assert_receive {AllForwarder, ^file_changed}

      project_compiled = project_compiled(project: make_ref())
      Dispatch.broadcast(project_compiled)
      assert_receive {AllForwarder, ^project_compiled}
    end
  end

  describe "selective handler" do
    defmodule SelectiveForwarder do
      use Dispatch.Handler, [
        project_compile_requested(),
        file_compiled()
      ]

      def on_event(event, test_pid) do
        send(test_pid, {__MODULE__, event})
        {:ok, test_pid}
      end
    end

    setup do
      Dispatch.add_handler(SelectiveForwarder, self())
    end

    test "forwards messages it cares about" do
      project_compile = project_compile_requested(project: make_ref())
      Dispatch.broadcast(project_compile)

      assert_receive {SelectiveForwarder, ^project_compile}

      file_compile = file_compiled(uri: "file:///foo.ex")
      Dispatch.broadcast(file_compile)

      assert_receive {SelectiveForwarder, ^file_compile}
    end

    test "ignores messages it doesn't subscribe to" do
      Dispatch.broadcast(file_changed())
      refute_receive {SelectiveForwarder, _}

      Dispatch.broadcast(project_compiled())
      refute_receive {SelectiveForwarder, _}
    end
  end

  describe "error handler" do
    defmodule ErrorForwarder do
      use Dispatch.Handler, [
        file_compiled(),
        project_compiled()
      ]

      def on_event(project_compiled(status: :failure) = project_compiled, caller_pid) do
        send(caller_pid, {__MODULE__, project_compiled})
        {:error, :died}
      end

      def on_event(event, caller_pid) do
        send(caller_pid, {__MODULE__, event})
      end
    end

    setup do
      Dispatch.add_handler(AllForwarder, self())
      Dispatch.add_handler(ErrorForwarder, self())
    end

    test "works for file compiled" do
      file_compiled = file_compiled(uri: "file:///something.ex")
      Dispatch.broadcast(file_compiled)

      assert_receive {AllForwarder, ^file_compiled}
      assert_receive {ErrorForwarder, ^file_compiled}
    end

    test "works for project compiled" do
      project_compiled = project_compiled(project: make_ref())
      Dispatch.broadcast(project_compiled)

      assert_receive {AllForwarder, ^project_compiled}
      assert_receive {ErrorForwarder, ^project_compiled}
    end

    test "removes a handler if it errors" do
      failure = project_compiled(status: :failure)
      Dispatch.broadcast(failure)

      assert_receive {AllForwarder, ^failure}
      assert_receive {ErrorForwarder, ^failure}

      # The error forwarder should now be removed

      Dispatch.broadcast(file_compiled())
      assert_receive {AllForwarder, _}
      refute_receive {ErrorForwarder, _}
    end
  end
end
