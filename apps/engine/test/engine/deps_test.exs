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
  end

  describe "project_files/0" do
    test "doesn't crash when Mix context is partial" do
      assert is_list(Deps.project_files())
    end
  end
end
