defmodule Engine.BuildTest do
  use ExUnit.Case

  alias Engine.Build
  alias Forge.Document

  describe "force_compile_document/1" do
    test "skips mix.exs files" do
      document =
        Document.new(
          "file:///workspace/project/mix.exs",
          "defmodule Example.MixProject do\nend\n",
          0
        )

      assert :ok = Build.force_compile_document(document)
    end
  end
end
