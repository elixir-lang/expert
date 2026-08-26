defmodule Forge.InternetTest do
  use ExUnit.Case, async: false
  use Patch

  alias Forge.Internet

  test "returns true when hex.pm resolves within five seconds" do
    patch(:inet_res, :getbyname, fn host, family, timeout ->
      assert host == ~c"hex.pm"
      assert family == :a
      assert timeout == 5_000

      {:ok, :hostent}
    end)

    assert Internet.connected_to_internet?()
  end

  test "returns false when hex.pm resolution fails" do
    patch(:inet_res, :getbyname, fn host, family, timeout ->
      assert host == ~c"hex.pm"
      assert family == :a
      assert timeout == 5_000

      {:error, :timeout}
    end)

    refute Internet.connected_to_internet?()
  end
end
