defmodule Engine.ApplicationCacheTest do
  use ExUnit.Case, async: false

  alias Engine.ApplicationCache

  @applications ApplicationCache.Applications
  @available_modules ApplicationCache.AvailableModules

  setup do
    start_supervised!(ApplicationCache)
    :ok
  end

  describe "application/1" do
    test "returns the owning application for a loaded module" do
      assert ApplicationCache.application(ApplicationCache) == :engine
    end

    test "caches missing applications as nil" do
      module = __MODULE__.UnknownModule

      assert ApplicationCache.application(module) == nil
      assert :ets.lookup(@applications, module) == [{module, nil}]
    end
  end

  describe "available_module?/1" do
    test "returns true for an available Erlang module" do
      assert ApplicationCache.available_module?(:timer) == true
    end

    test "returns false for an unavailable module" do
      assert ApplicationCache.available_module?(__MODULE__.UnknownModule) == false
    end
  end

  describe "clear/0" do
    test "clears application lookups" do
      assert ApplicationCache.application(ApplicationCache) == :engine
      assert :ets.lookup(@applications, ApplicationCache) == [{ApplicationCache, :engine}]

      assert ApplicationCache.clear() == :ok

      assert :ets.lookup(@applications, ApplicationCache) == []
    end

    test "reloads available modules" do
      assert ApplicationCache.available_module?(:timer)

      :ets.delete_all_objects(@available_modules)
      refute ApplicationCache.available_module?(:timer)

      assert ApplicationCache.clear() == :ok
      assert ApplicationCache.available_module?(:timer)
    end
  end
end
