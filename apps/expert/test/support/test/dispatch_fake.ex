defmodule Expert.Test.DispatchFake do
  alias Engine.Dispatch

  defmacro __using__(_) do
    quote do
      require unquote(__MODULE__)
    end
  end

  # This is a macro because patch requires that you're in a unit test, and have a setup block
  # We need to defer the patch macros until we get inside a unit test context, and the macro
  # does that for us.
  defmacro start do
    quote do
      patch(Expert.EngineApi, :register_listener, fn _project, listener_pid, message_types ->
        Dispatch.register_listener(listener_pid, message_types)
      end)

      patch(Expert.EngineApi, :broadcast, fn _project, message ->
        Dispatch.broadcast(message)
      end)

      start_supervised!(Dispatch)
    end
  end
end
