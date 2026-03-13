defmodule Forge.Document.LineParserTest do
  use ExUnit.Case
  use ExUnitProperties

  import Forge.Document.Line

  alias Forge.Document.LineParser

  test "parsing a single \n" do
    assert length(LineParser.parse("\n", 1)) == 1
  end

  def parse(lines) do
    LineParser.parse(lines, 1)
  end

  describe "parsing lines" do
    test "with an empty string" do
      assert [] = parse("")
    end

    test "beginning with endline" do
      assert [line(text: "", ending: "\n", ascii?: true)] = parse("\n")

      assert [
               line(text: "", ending: "\n", ascii?: true),
               line(text: "basic", ending: "", ascii?: true)
             ] = parse("\nbasic")
    end

    test "without any endings" do
      assert [line(text: "basic", ending: "")] = parse("basic")
    end

    test "with a LF" do
      assert [line(text: "text", ending: "\n")] = parse("text\n")
    end

    test "with a CR LF" do
      assert [line(text: "text", ending: "\r\n")] = parse("text\r\n")
    end

    test "with a CR" do
      assert [line(text: "text", ending: "\r")] = parse("text\r")
    end

    test "with multiple LF lines" do
      assert [
               line(text: "line1", ending: "\n"),
               line(text: "line2", ending: "\n"),
               line(text: "line3", ending: "")
             ] = parse("line1\nline2\nline3")
    end

    test "with multiple CR LF line endings" do
      text = "A\r\nB\r\n\r\nC"

      assert [
               line(text: "A", ending: "\r\n"),
               line(text: "B", ending: "\r\n"),
               line(text: "", ending: "\r\n"),
               line(text: "C", ending: "")
             ] = parse(text)
    end

    test "with an emoji" do
      text = "👨‍👩‍👦 test"
      assert [line(text: ^text, ending: "", ascii?: false)] = parse(text)
    end

    test "example multi-byte string" do
      text = "𐂀"

      assert String.valid?(text)
      [line(text: line, ending: "", ascii?: false)] = parse(text)
      assert String.valid?(line)
    end

    test "a utf-16 line" do
      utf8_text = "this is probably on windows. Sorry"
      utf16_text = :unicode.characters_to_binary(utf8_text, :utf8, :utf16)

      assert [line(text: text, ascii?: false, ending: "")] = parse(utf16_text)
      assert utf8_text == :unicode.characters_to_binary(text, :utf16, :utf8)
    end
  end

  property "random files" do
    check all(
            lines <-
              list_of(string(:alphanumeric, min_length: 2, max_length: 120), min_length: 1),
            ending <- member_of(["\r", "\n", "\r\n"])
          ) do
      file_contents = Enum.join(lines, ending) <> ending
      parsed = LineParser.parse(file_contents, 1)

      for {orig_line, line(text: text, ending: line_ending)} <- Enum.zip(lines, parsed) do
        assert String.starts_with?(orig_line, text)
        assert line_ending == ending
      end
    end
  end
end
