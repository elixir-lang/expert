defprotocol ProtocolDiagnostics.Protocol do
  def call(value)
end

defimpl ProtocolDiagnostics.Protocol, for: Atom do
  def call(value), do: value
end
