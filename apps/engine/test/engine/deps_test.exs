defmodule Engine.DepsTest do
  use ExUnit.Case, async: true

  alias Engine.Deps

  describe "dep_version/1" do
    test "returns the version of a loaded OTP application (atom form)" do
      # `:elixir` is always loaded in any Elixir test environment, so
      # we can rely on its application spec without staging anything.
      assert {:ok, version} = Deps.dep_version(:elixir)
      assert is_binary(version)
      assert Regex.match?(~r/^\d+\.\d+/, version)
    end

    test "returns the version of a loaded OTP application (string form)" do
      # Binaries are routed through `String.to_existing_atom/1`, which
      # only succeeds when the atom is already registered — `:elixir`
      # qualifies.
      assert {:ok, version} = Deps.dep_version("elixir")
      assert is_binary(version)
    end

    test "returns :error when the atom does not correspond to a loaded app" do
      assert :error = Deps.dep_version(:this_app_is_not_loaded_at_all)
    end

    test "returns :error for a binary that has never been interned as an atom" do
      # `String.to_existing_atom` raises `ArgumentError` when the atom
      # has never been seen — we catch that and return `:error` so
      # Expert passing a package name the project doesn't depend on
      # can't leak atoms into the engine node.
      assert :error =
               Deps.dep_version("definitely_not_a_real_atom_xyz_#{System.unique_integer()}")
    end
  end

  describe "project_file/1" do
    test "returns a string or nil (doesn't crash when Mix context is partial)" do
      assert :app |> Deps.project_file() |> is_nil_or_string()
      assert :umbrella |> Deps.project_file() |> is_nil_or_string()
    end
  end

  describe "project_files/0" do
    test "returns a list (possibly empty)" do
      assert is_list(Deps.project_files())
    end
  end

  defp is_nil_or_string(nil), do: true
  defp is_nil_or_string(s) when is_binary(s), do: true
  defp is_nil_or_string(_), do: false
end
