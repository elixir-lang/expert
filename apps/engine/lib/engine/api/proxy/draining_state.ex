defmodule Engine.Api.Proxy.DrainingState do
  alias Engine.Api.Proxy.BufferingState
  alias Engine.Api.Proxy.ProxyingState
  alias Engine.Api.Proxy.Records

  import Records

  defstruct [:proxying_state, :buffering_state]

  def new(%BufferingState{} = buffering_state, %ProxyingState{} = proxying_state) do
    %__MODULE__{buffering_state: buffering_state, proxying_state: proxying_state}
  end

  def drained?(%__MODULE__{} = state) do
    ProxyingState.empty?(state.proxying_state)
  end

  def consume_reply(%__MODULE__{} = state, ref) when is_reference(ref) do
    %__MODULE__{state | proxying_state: ProxyingState.consume_reply(state.proxying_state, ref)}
  end

  def reply(%__MODULE__{} = state, ref, reply) do
    ProxyingState.reply(state.proxying_state, ref, reply)
  end

  def add_mfa(%__MODULE__{} = state, mfa() = mfa) do
    new_buffering_state = BufferingState.add_mfa(state.buffering_state, mfa)
    %__MODULE__{state | buffering_state: new_buffering_state}
  end
end
