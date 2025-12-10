defmodule Expert.Test.Protocol.TransportSupport do
  def with_patched_transport(_ \\ nil) do
    test = self()

    Patch.patch(GenLSP, :notify_server, fn _, message ->
      send(test, {:transport, message})
    end)

    Patch.patch(GenLSP, :notify, fn _, message ->
      send(test, {:transport, message})
    end)

    Patch.patch(GenLSP, :request, fn _, message ->
      send(test, {:transport, message})
    end)

    :ok
  end
end
