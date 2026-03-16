defmodule Forge.ProcessCacheTest do
  use ExUnit.Case
  use Patch

  import Forge.ProcessCache

  alias Forge.ProcessCache

  setup do
    expose(ProcessCache.Entry, now_ts: 0)
    {:ok, now: 1}
  end

  describe "trans/2" do
    test "calls the compute function" do
      assert 3 == trans("my key", fn -> 3 end)
    end

    test "pulls from the process cache when an entry exists" do
      assert 3 == trans("my key", fn -> 3 end)
      assert 3 == trans("my key", fn -> 6 end)
    end

    test "times out after a given timeout", ctx do
      now = ctx.now

      patch(ProcessCache.Entry, :now_ts, cycle([now, now + 4999, now + 5000]))

      assert 3 == trans("my key", fn -> 3 end)
      assert {:ok, 3} == fetch("my key")
      assert :error == fetch("my key")
    end

    test "calling get also clears the key after the timeout", ctx do
      now = ctx.now

      patch(ProcessCache.Entry, :now_ts, cycle([now, now + 4999, now + 5000]))

      assert 3 == trans("my key", fn -> 3 end)
      assert 3 == get("my key")
      assert nil == get("my key")
    end

    test "the timeout is configurable", ctx do
      now = ctx.now
      patch(ProcessCache.Entry, :now_ts, cycle([now, now + 49, now + 50]))

      assert 3 = trans("my key", 50, fn -> 3 end)
      assert {:ok, 3} == fetch("my key")
      assert :error == fetch("my key")
    end

    test "trans will replace an expired key", ctx do
      now = ctx.now
      patch(ProcessCache.Entry, :now_ts, cycle([now, now + 49, now + 50]))

      assert 3 = trans("my key", 50, fn -> 3 end)
      assert 3 = trans("my key", 50, fn -> 6 end)
      assert 6 = trans("my key", 50, fn -> 6 end)
    end
  end

  describe "with_cleanup" do
    test "cleans up after a trans call" do
      with_cleanup do
        trans("my_key", fn -> 3 end)
      end

      assert :error = fetch("my_key")
    end

    test "cleans up multiple keys" do
      with_cleanup do
        trans("my_key", fn -> 1 end)
        trans("my_key2", fn -> 1 end)
        trans("my_key3", fn -> 1 end)
      end

      assert :error = fetch("my_key")
      assert :error = fetch("my_key1")
      assert :error = fetch("my_key2")
    end

    test "cleans up even if a trans function raises" do
      with_cleanup do
        assert_raise RuntimeError, fn ->
          with_cleanup do
            trans("my_key", fn -> 1 end)
            trans("my_key2", fn -> 1 end)
            trans("my_key3", fn -> raise "oops" end)
          end
        end

        assert :error = fetch("my_key")
        assert :error = fetch("my_key2")
        assert :error = fetch("my_key3")
      end
    end

    test "returns the last value" do
      result =
        with_cleanup do
          trans("my_key", fn -> 1 end) + 1
        end

      assert result == 2
    end
  end
end
