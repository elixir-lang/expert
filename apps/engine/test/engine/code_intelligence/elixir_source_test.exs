defmodule Engine.CodeIntelligence.ElixirSourceTest do
  use ExUnit.Case, async: true

  alias Engine.CodeIntelligence.ElixirSource

  describe "detect/0" do
    test "returns the source root of the running Elixir installation" do
      root = ElixirSource.detect()

      assert is_binary(root)
      assert File.exists?(Path.join(root, "lib/elixir/lib/kernel.ex"))
    end
  end
end
