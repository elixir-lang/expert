defmodule Engine.ModuleMappingsTest do
  alias Engine.Dispatch
  alias Engine.ModuleMappings

  use ExUnit.Case
  use Forge.Test.EventualAssertions

  import Forge.EngineApi.Messages

  setup do
    start_supervised!(Dispatch)
    start_supervised!(ModuleMappings)
    :ok
  end

  def with_a_populated_cache(_) do
    update_module(__MODULE__, __ENV__.file)
    :ok
  end

  def update_module(module, file) do
    Dispatch.broadcast(module_updated(name: module, file: file))
  end

  describe "modules_in_file/1" do
    test "returns an empty list if the file isn't in the cache" do
      assert ModuleMappings.modules_in_file("/does/not/exist.ex") == []
    end
  end

  describe "basic functions" do
    setup [:with_a_populated_cache]

    test "it updates the file for a module" do
      update_module(__MODULE__, "foo.text")

      assert_eventually ModuleMappings.file_for_module(__MODULE__) == "foo.text"
    end

    test "it allows you to get the file of a module" do
      assert_eventually ModuleMappings.file_for_module(__MODULE__) == __ENV__.file
    end

    test "it allows you to get the modules defined in a file" do
      assert_eventually ModuleMappings.modules_in_file(__ENV__.file) == [__MODULE__]
    end

    test "it allows to get multiple modules defined in a file" do
      update_module(FakeModule, __ENV__.file)

      assert_eventually [FakeModule, __MODULE__] = ModuleMappings.modules_in_file(__ENV__.file)
    end

    test "it allows for modules to move from one file to another" do
      update_module(__MODULE__, "other_file.exs")

      assert_eventually ModuleMappings.file_for_module(__MODULE__) == "other_file.exs"
      assert_eventually ModuleMappings.modules_in_file(__ENV__.file) == []
    end
  end
end
