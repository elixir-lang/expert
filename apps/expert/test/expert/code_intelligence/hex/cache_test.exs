defmodule Expert.CodeIntelligence.Hex.CacheTest do
  use ExUnit.Case, async: true

  alias Expert.CodeIntelligence.Hex.Cache

  setup do
    name = :"hex_cache_test_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{name}.dets")
    on_exit(fn -> File.rm(path) end)

    start_supervised!({Cache, name: name, path: path})
    {:ok, cache: name}
  end

  describe "get_or_fetch/4" do
    test "returns the fetched value on a cache miss and stores it", %{cache: cache} do
      assert {:ok, "v1"} =
               Cache.get_or_fetch(cache, "k", 60_000, fn -> {:ok, "v1"} end)

      # Second call should not invoke the fetcher.
      assert {:ok, "v1"} =
               Cache.get_or_fetch(cache, "k", 60_000, fn ->
                 flunk("fetcher should not be called for fresh hit")
               end)
    end

    test "re-fetches once the entry is older than ttl_ms", %{cache: cache} do
      Cache.get_or_fetch(cache, "k", 60_000, fn -> {:ok, "v1"} end)

      # ttl_ms = 0 forces every entry to be considered stale.
      assert {:ok, "v2"} =
               Cache.get_or_fetch(cache, "k", 0, fn -> {:ok, "v2"} end)
    end

    test "falls back to a stale value when the fetcher errors", %{cache: cache} do
      Cache.get_or_fetch(cache, "k", 60_000, fn -> {:ok, "v1"} end)

      assert {:ok, "v1"} =
               Cache.get_or_fetch(cache, "k", 0, fn -> {:error, :nxdomain} end)
    end

    test "propagates the error when there is no stale value to serve", %{cache: cache} do
      assert {:error, :nxdomain} =
               Cache.get_or_fetch(cache, "k", 60_000, fn -> {:error, :nxdomain} end)
    end
  end

  describe "persistence" do
    test "values survive a server restart", %{cache: cache} do
      Cache.get_or_fetch(cache, "k", 60_000, fn -> {:ok, "v1"} end)

      :ok = stop_supervised!(Cache)
      path = Path.join(System.tmp_dir!(), "#{cache}.dets")
      start_supervised!({Cache, name: cache, path: path})

      assert {:ok, "v1"} =
               Cache.get_or_fetch(cache, "k", 60_000, fn ->
                 flunk("fetcher should not be called after restart")
               end)
    end
  end
end
