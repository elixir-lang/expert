defmodule Forge.MathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Forge.Math

  describe "clamp/3" do
    test "returns low when value is less than low" do
      assert Math.clamp(-5, 0, 5) == 0
    end

    test "returns value when value is between low and high" do
      assert Math.clamp(3, 0, 5) == 3
    end

    test "returns high when value is greater than high" do
      assert Math.clamp(6, 0, 5) == 5
    end
  end

  def low_mid_high(unique_list) do
    [low | rest] = Enum.sort(unique_list)

    mid_index = trunc(length(rest) / 2)
    mid = Enum.at(rest, mid_index)
    high = List.last(rest)
    [low, mid, high]
  end

  property "clamp works with all integers" do
    check all(ints <- uniq_list_of(integer(-100_000..100_000), min_length: 5, max_length: 20)) do
      [low, mid, high] = low_mid_high(ints)
      assert Math.clamp(mid, low, high) == mid
      assert Math.clamp(low, mid, high) == mid
      assert Math.clamp(high, low, mid) == mid
    end
  end
end
