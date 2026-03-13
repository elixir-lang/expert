defmodule Forge.CodeUnitTest do
  use ExUnit.Case

  import Forge.CodeUnit

  describe "utf8_position_to_utf16_offset/2" do
    test "handles single-byte characters" do
      s = "do"
      assert 0 == utf8_position_to_utf16_offset(s, 0)
      assert 1 == utf8_position_to_utf16_offset(s, 1)
      assert 2 == utf8_position_to_utf16_offset(s, 2)
      assert 2 == utf8_position_to_utf16_offset(s, 3)
      assert 2 == utf8_position_to_utf16_offset(s, 4)
    end

    test "caps offsets at the end of the string and beyond" do
      line = "🎸"
      assert 2 == utf8_position_to_utf16_offset(line, 1)
      assert 2 == utf8_position_to_utf16_offset(line, 2)
      assert 2 == utf8_position_to_utf16_offset(line, 3)
      assert 2 == utf8_position_to_utf16_offset(line, 4)
    end

    test "handles multi-byte characters properly" do
      # guitar is 2 code units in utf16 but 4 in utf8
      line = "b🎸abc"
      assert 0 == utf8_position_to_utf16_offset(line, 0)
      assert 1 == utf8_position_to_utf16_offset(line, 1)
      assert 3 == utf8_position_to_utf16_offset(line, 2)
      assert 4 == utf8_position_to_utf16_offset(line, 3)
      assert 5 == utf8_position_to_utf16_offset(line, 4)
      assert 6 == utf8_position_to_utf16_offset(line, 5)
      assert 6 == utf8_position_to_utf16_offset(line, 6)
    end
  end

  describe "utf16_offset_to_utf8_offset" do
    test "with a multi-byte character" do
      line = "🏳️‍🌈"

      code_unit_count = count_utf8_code_units(line)

      assert utf16_offset_to_utf8_offset(line, 0) == {:ok, 1}
      assert utf16_offset_to_utf8_offset(line, 1) == {:error, :misaligned}
      assert utf16_offset_to_utf8_offset(line, 2) == {:ok, 5}
      assert utf16_offset_to_utf8_offset(line, 3) == {:ok, 8}
      assert utf16_offset_to_utf8_offset(line, 4) == {:ok, 11}
      assert utf16_offset_to_utf8_offset(line, 5) == {:error, :misaligned}
      assert utf16_offset_to_utf8_offset(line, 6) == {:ok, code_unit_count + 1}
    end

    test "after a unicode character" do
      line = ~s(    {"🎸",   "ok"})

      assert utf16_offset_to_utf8_offset(line, 0) == {:ok, 1}
      assert utf16_offset_to_utf8_offset(line, 1) == {:ok, 2}
      assert utf16_offset_to_utf8_offset(line, 4) == {:ok, 5}
      assert utf16_offset_to_utf8_offset(line, 5) == {:ok, 6}
      assert utf16_offset_to_utf8_offset(line, 6) == {:ok, 7}
      assert utf16_offset_to_utf8_offset(line, 7) == {:error, :misaligned}
      # after the guitar character
      assert utf16_offset_to_utf8_offset(line, 8) == {:ok, 11}
      assert utf16_offset_to_utf8_offset(line, 9) == {:ok, 12}
      assert utf16_offset_to_utf8_offset(line, 10) == {:ok, 13}
      assert utf16_offset_to_utf8_offset(line, 11) == {:ok, 14}
      assert utf16_offset_to_utf8_offset(line, 12) == {:ok, 15}
      assert utf16_offset_to_utf8_offset(line, 13) == {:ok, 16}
      assert utf16_offset_to_utf8_offset(line, 17) == {:ok, 20}
    end
  end

  defp count_utf8_code_units(utf8_string) do
    byte_size(utf8_string)
  end
end
