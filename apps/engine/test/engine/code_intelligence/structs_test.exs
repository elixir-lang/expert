defmodule Engine.CodeIntelligence.StructsTest do
  use ExUnit.Case
  use Patch

  alias Engine.CodeIntelligence.Structs
  alias Engine.Search.Store
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  test "returns indexed struct definitions without requiring loaded modules" do
    struct_module = Module.concat(__MODULE__, IndexedOnlyStruct)

    patch(Engine, :get_project, fn -> %Project{kind: :bare} end)

    patch(Store, :exact, fn [type: :struct, subtype: :definition] ->
      {:ok, [%Entry{subject: struct_module}]}
    end)

    assert Structs.for_project() == {:ok, [struct_module]}
  end
end
