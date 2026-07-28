defmodule ProtocolDiagnostics.Caller do
  def call(value), do: ProtocolDiagnostics.Protocol.call(value)
end
