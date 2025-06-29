defmodule ParseErrors do
  def parse_errors([uri: uri, diagnostics: diagnostics], state) do
    state = State.clear(state, uri)
    state = Enum.reduce(diagnostics, state, fn diagnostic, state ->
      case State.add(diagnostic, state, uri) do
        {:ok, new_state} ->
          new_state
        {:error, reason} ->
          Logger.error("Could not add diagnostic #{inspect(diagnostic)} because #{inspect error}")
          state
      end
    end

    publish_diagnostics(state)
  end
end
