defmodule Forge.CodeTest do
  use ExUnit.Case, async: true

  alias Forge.Code

  describe "parse_mfa/1" do
    test "parses Elixir module MFA strings" do
      result = Code.parse_mfa("Enum.map/2")
      assert {Enum, :map, 2} = result
    end

    test "parses Erlang module MFA strings" do
      result = Code.parse_mfa(":lists.reverse/1")
      assert {:lists, :reverse, 1} = result
    end

    test "returns nil for non-existent Elixir modules" do
      result = Code.parse_mfa("NonExistentModule.some_function/1")
      assert result == nil
    end

    test "returns nil for non-existent Erlang modules" do
      result = Code.parse_mfa(":non_existent_erlang_module.some_function/1")
      assert result == nil
    end

    test "returns nil for invalid MFA format" do
      assert Code.parse_mfa("invalid") == nil
      assert Code.parse_mfa("Module.without.arity") == nil
      assert Code.parse_mfa("Module.function/") == nil
      assert Code.parse_mfa("/function/1") == nil
    end
  end
end
