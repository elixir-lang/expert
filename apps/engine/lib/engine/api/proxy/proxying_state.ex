defmodule Engine.Api.Proxy.ProxyingState do
  alias Engine.Api.Proxy.Records

  defstruct refs_to_from: %{}

  import Records

  def new do
    %__MODULE__{}
  end

  def apply_mfa(
        %__MODULE__{} = state,
        from,
        mfa(module: module, function: function, arguments: arguments)
      ) do
    task = Task.async(module, function, arguments)

    %__MODULE__{
      state
      | refs_to_from: Map.put(state.refs_to_from, task.ref, from)
    }
  end

  def reply(%__MODULE__{} = state, ref, reply) when is_reference(ref) do
    case Map.fetch(state.refs_to_from, ref) do
      {:ok, from} ->
        :gen_statem.reply(from, reply)

      _ ->
        :ok
    end
  end

  def consume_reply(%__MODULE__{} = state, ref) when is_reference(ref) do
    %__MODULE__{state | refs_to_from: Map.delete(state.refs_to_from, ref)}
  end

  def empty?(%__MODULE__{} = state) do
    Enum.empty?(state.refs_to_from)
  end
end
