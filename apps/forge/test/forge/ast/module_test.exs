defmodule Forge.Ast.ModuleTest do
  use ExUnit.Case, async: true

  import Forge.Ast.Module

  describe "safe_split/2" do
    test "splits elixir modules into binaries by default" do
      assert {:elixir, ~w(Forge Document Store)} == safe_split(Forge.Document.Store)
    end

    test "splits elixir modules into binaries" do
      assert {:elixir, ~w(Forge Document Store)} ==
               safe_split(Forge.Document.Store, as: :binaries)
    end

    test "splits elixir modules into atoms" do
      assert {:elixir, ~w(Forge Document Store)a} ==
               safe_split(Forge.Document.Store, as: :atoms)
    end

    test "splits erlang modules" do
      assert {:erlang, ["ets"]} = safe_split(:ets)
      assert {:erlang, ["ets"]} = safe_split(:ets, as: :binaries)
      assert {:erlang, [:ets]} = safe_split(:ets, as: :atoms)
    end
  end
end
