defmodule Engine.DepsTest do
  use ExUnit.Case, async: true

  alias Engine.Deps

  describe "dep_version/1" do
    test "returns the version of a loaded OTP application (atom form)" do
      assert {:ok, version} = Deps.dep_version(:elixir)
      assert is_binary(version)
      assert Regex.match?(~r/^\d+\.\d+/, version)
    end

    test "returns :error when the atom does not correspond to a loaded app" do
      assert :error = Deps.dep_version(:this_app_is_not_loaded_at_all)
    end

    test "returns the version when given a string matching a loaded app" do
      assert {:ok, version} = Deps.dep_version("elixir")
      assert is_binary(version)
      assert Regex.match?(~r/^\d+\.\d+/, version)
    end

    test "returns :error when the string does not match any existing atom" do
      assert :error = Deps.dep_version("zzz_no_such_app_exists_ever")
    end
  end
end
