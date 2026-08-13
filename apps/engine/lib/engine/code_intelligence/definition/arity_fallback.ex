defmodule Engine.CodeIntelligence.Definition.ArityFallback do
  @moduledoc false

  def other_arities(exports, function, requested_arity) do
    exports
    |> Enum.flat_map(fn
      {^function, {arity, _}} when arity != requested_arity -> [arity]
      _ -> []
    end)
    |> Enum.sort()
  end
end
