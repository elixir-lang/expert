defmodule Forge.FormatsTest do
  use ExUnit.Case

  alias Forge.Formats

  describe "stringifying modules" do
    test "it correctly handles a top-level module" do
      assert "Forge" == Formats.module(Forge)
    end

    test "it correctly handles a nested module" do
      assert "Forge.Text" == Formats.module(Forge.Text)
    end

    test "it correctly handles an erlang module name" do
      assert ":ets" == Formats.module(:ets)
    end

    test "it drops any `Elixir.` prefix" do
      assert "Kernel.SpecialForms" == Formats.module(Elixir.Kernel.SpecialForms)
    end

    test "it correctly handles an invalid elixir module" do
      assert "This.Is.Not.A.Module" == Formats.module(:"This.Is.Not.A.Module")
    end
  end

  describe "formatting time" do
    test "it handles milliseconds" do
      assert "1.0 seconds" = Formats.time(1000, unit: :millisecond)
      assert "1.5 seconds" = Formats.time(1500, unit: :millisecond)
    end

    test "microseconds is the default" do
      assert "150 ms" = Formats.time(150_000)
    end

    test "it handles microseconds" do
      assert "2 ms" = Formats.time(2000)
      assert "0.2 ms" = Formats.time(200)
      assert "0.02 ms" = Formats.time(20)
    end
  end

  describe "plural/3" do
    test "returns singular when count is 1" do
      assert Formats.plural(1, "${count} apple", "${count} apples") == "1 apple"
    end

    test "returns plural when count is not 1" do
      assert Formats.plural(0, "${count} apple", "${count} apples") == "0 apples"
      assert Formats.plural(2, "${count} apple", "${count} apples") == "2 apples"
      assert Formats.plural(3, "${count} apple", "${count} apples") == "3 apples"
    end
  end
end
