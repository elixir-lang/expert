defmodule Forge.InternetTest do
  use ExUnit.Case, async: false
  use Patch

  alias Forge.Internet

  test "returns true when the OS resolver finds hex.pm within five seconds" do
    patch(:inet, :gethostbyname, fn host, family ->
      assert host == ~c"hex.pm"
      assert family == :inet

      {:ok, :hostent}
    end)

    assert Internet.connected_to_internet?()
  end

  test "returns false when OS resolution fails" do
    patch(:inet, :gethostbyname, fn host, family ->
      assert host == ~c"hex.pm"
      assert family == :inet

      {:error, :timeout}
    end)

    refute Internet.connected_to_internet?()
  end

  @tag timeout: 10_000
  test "returns false after five seconds and terminates a blocked resolver" do
    caller = self()

    patch(:inet, :gethostbyname, fn _host, _family ->
      Process.flag(:trap_exit, true)
      send(caller, {:resolver_started, self()})
      Process.sleep(:infinity)
    end)

    {elapsed_us, connected?} = :timer.tc(fn -> Internet.connected_to_internet?() end)

    refute connected?

    assert_receive {:resolver_started, pid}
    refute Process.alive?(pid)
    refute_receive {_ref, _result}
    refute_receive {:DOWN, _ref, :process, ^pid, _reason}

    assert elapsed_us >= 5_000_000
    assert elapsed_us < 6_000_000, "expected a five-second timeout, took #{elapsed_us} us"
  end
end
