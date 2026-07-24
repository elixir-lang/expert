arity_fallback =
  Path.expand(
    "../../../../lib/engine/code_intelligence/definition/arity_fallback.ex",
    __DIR__
  )

unless Code.ensure_loaded?(Engine.CodeIntelligence.Definition.ArityFallback) do
  Code.require_file(arity_fallback)
end

if is_nil(Process.whereis(ExUnit.Server)), do: ExUnit.start()

defmodule Engine.CodeIntelligence.Definition.ArityFallbackTest do
  use ExUnit.Case, async: true

  alias Engine.CodeIntelligence.Definition.ArityFallback

  test "returns sorted other arities for the requested function" do
    exports = [
      other_function: {2, :function},
      requested_function: {3, :function},
      requested_function: {1, :function},
      requested_function: {4, :function}
    ]

    assert ArityFallback.other_arities(exports, :requested_function, 4) == [1, 3]
  end
end
