defmodule Forge.DocumentTest do
  alias Forge.Document

  alias GenLSP.Structures.Position
  alias GenLSP.Structures.Range
  alias GenLSP.Structures.TextEdit

  use ExUnit.Case

  import Forge.Document, except: [to_string: 1]

  def text(%Forge.Document{} = doc) do
    Document.to_string(doc)
  end

  def with_a_simple_module(_) do
    module = """
    defmodule MyModule do
      def foo, do: 3

      def bar(a, b) do
        a + b
      end
    end
    """

    {:ok, module: module}
  end

  def file_uri do
    "file:///elixir.ex"
  end

  def edit(text) do
    %TextEdit{new_text: text, range: nil}
  end

  def edit(text, range) do
    %TextEdit{new_text: text, range: range}
  end

  describe "new" do
    setup [:with_a_simple_module]

    test "it should handle out of bounds lines" do
      doc = new(file_uri(), "hello", 1)

      assert :error = fetch_line_at(doc, 0)
      assert :error = fetch_text_at(doc, 0)

      assert :error = fetch_line_at(doc, -1)
      assert :error = fetch_text_at(doc, -1)

      assert :error = fetch_line_at(doc, 2)
      assert :error = fetch_text_at(doc, 2)
    end

    test "it should be able to parse a single line" do
      assert parsed = new(file_uri(), "hello", 1)

      assert {:ok, "hello"} = fetch_text_at(parsed, 1)
    end

    test "it should parse its input into lines", ctx do
      assert parsed = new(file_uri(), ctx.module, 100)
      refute parsed.dirty?
      assert parsed.version == 100

      assert {:ok, "defmodule MyModule do"} = fetch_text_at(parsed, 1)
      assert {:ok, "  def foo, do: 3"} = fetch_text_at(parsed, 2)
      assert {:ok, ""} = fetch_text_at(parsed, 3)
      assert {:ok, "  def bar(a, b) do"} = fetch_text_at(parsed, 4)
      assert {:ok, "    a + b"} = fetch_text_at(parsed, 5)
      assert {:ok, "  end"} = fetch_text_at(parsed, 6)
      assert {:ok, "end"} = fetch_text_at(parsed, 7)

      assert :error = fetch_text_at(parsed, 8)
    end
  end

  describe "applying protocol content change events" do
    test "applying a text only change replaces all the test" do
      {:ok, doc} =
        run_changes("hello", [%{text: "goodbye"}])

      assert "goodbye" = text(doc)
    end

    test "applying a range event replaces the range" do
      range_change =
        %{
          range: new_range(0, 6, 1, 0),
          text: "people"
        }

      {:ok, doc} = run_changes("hello there", [range_change])
      assert "hello people" == text(doc)
    end

    test "applying batched incremental changes" do
      content = """
      defmodule Proxy do
        String.dow
      end
      """

      expected = """
      defmodule Proxy do
        String.downcase(string)
      end
      """

      changes = [
        %{text: "", range: new_range(1, 11, 1, 12), range_length: 1},
        %{text: "", range: new_range(1, 10, 1, 11), range_length: 1},
        %{text: "", range: new_range(1, 9, 1, 10), range_length: 1},
        %{text: "d", range: new_range(1, 9, 1, 9), range_length: 0},
        %{text: "o", range: new_range(1, 10, 1, 10), range_length: 0},
        %{text: "w", range: new_range(1, 11, 1, 11), range_length: 0},
        %{text: "n", range: new_range(1, 12, 1, 12), range_length: 0},
        %{text: "c", range: new_range(1, 13, 1, 13), range_length: 0},
        %{text: "a", range: new_range(1, 14, 1, 14), range_length: 0},
        %{text: "s", range: new_range(1, 15, 1, 15), range_length: 0},
        %{text: "e", range: new_range(1, 16, 1, 17), range_length: 0},
        %{text: "", range: new_range(1, 9, 1, 17), range_length: 8},
        %{text: "", range: new_range(1, 9, 1, 9), range_length: 0},
        %{text: "downcase(", range: new_range(1, 9, 1, 9), range_length: 0},
        %{text: "string", range: new_range(1, 18, 1, 18), range_length: 0},
        %{text: ")", range: new_range(1, 24, 1, 24), range_length: 0},
        %{text: "", range: new_range(1, 25, 1, 25), range_length: 0}
      ]

      {:ok, doc} = run_changes(content, changes)

      assert text(doc) == expected
    end
  end

  describe "apply_content_changes" do
    # tests and helper functions ported from https://github.com/microsoft/vscode-languageserver-node
    # note that those functions are not production quality e.g. they don't deal with utf8/utf16 encoding issues
    defp index_of(string, substring) do
      case String.split(string, substring, parts: 2) do
        [left, _] -> left |> String.codepoints() |> length
        [_] -> -1
      end
    end

    def get_line_offsets(text) do
      text
      |> String.codepoints()
      |> do_line_offset(1, 0, [{0, 0}])
    end

    def do_line_offset([], _current_line, _current_index, offsets) do
      Map.new(offsets)
    end

    def do_line_offset(["\r", "\n" | rest], current_line, current_index, offsets) do
      do_line_offset(rest, current_line + 1, current_index + 2, [
        {current_line, current_index + 2} | offsets
      ])
    end

    def do_line_offset(["\n" | rest], current_line, current_index, offsets) do
      do_line_offset(rest, current_line + 1, current_index + 1, [
        {current_line, current_index + 1} | offsets
      ])
    end

    def do_line_offset(["\r" | rest], current_line, current_index, offsets) do
      do_line_offset(rest, current_line + 1, current_index + 1, [
        {current_line, current_index + 1} | offsets
      ])
    end

    def do_line_offset([_c | rest], current_line, current_index, offsets) do
      do_line_offset(rest, current_line, current_index + 1, offsets)
    end

    defp find_low_high(low, high, offset, line_offsets) when low < high do
      mid = floor((low + high) / 2)

      if line_offsets[mid] > offset do
        find_low_high(low, mid, offset, line_offsets)
      else
        find_low_high(mid + 1, high, offset, line_offsets)
      end
    end

    defp find_low_high(low, _high, _offset, _line_offsets), do: low

    def position_at(text, offset) do
      offset = clamp(offset, 0, text |> String.codepoints() |> length)

      line_offsets = get_line_offsets(text)
      low = 0
      high = map_size(line_offsets)

      if high == 0 do
        %Position{line: 0, character: offset}
      else
        low = find_low_high(low, high, offset, line_offsets)

        # low is the least x for which the line offset is larger than the current offset
        # or array.length if no line offset is larger than the current offset
        line = low - 1
        %Position{line: line, character: offset - line_offsets[line]}
      end
    end

    def clamp(num, low, high) do
      num
      |> max(low)
      |> min(high)
    end

    def new_position(l, c) do
      %Position{line: l, character: c}
    end

    def position_after_substring(text, sub_text) do
      index = index_of(text, sub_text)

      position_at(text, index + (sub_text |> String.to_charlist() |> length))
    end

    def range_for_substring(doc, sub_text) do
      index = index_of(doc, sub_text)

      substring_len =
        sub_text
        |> String.to_charlist()
        |> length()

      %Range{
        start: position_at(doc, index),
        end: position_at(doc, index + substring_len)
      }
    end

    def range_after_substring(doc_text, sub_text) do
      pos = position_after_substring(doc_text, sub_text)
      %Range{start: pos, end: pos}
    end

    def new_range(sl, sc, el, ec) do
      %Range{start: new_position(sl, sc), end: new_position(el, ec)}
    end

    def run_changes(original, changes, opts \\ []) do
      final_version = Keyword.get(opts, :version, 1)
      document = new(file_uri(), original, 0)
      apply_content_changes(document, final_version, changes)
    end

    test "empty update" do
      assert {:ok, doc} = run_changes("abc123", [], version: 1)
      assert "abc123" == text(doc)
      assert doc.version == 0
    end

    test "update on empty document" do
      assert {:ok, doc} = run_changes("", [], version: 1)
      assert "" == text(doc)
      assert doc.version == 0
    end

    test "setting the version" do
      assert {:ok, doc} = run_changes("abc123", [edit("mornin")], version: 3)
      assert "mornin" == text(doc)
      assert doc.version == 3
    end

    test "full update" do
      assert {:ok, doc} = run_changes("abc123", [edit("efg456")])
      assert "efg456" == text(doc)
      assert doc.version == 1

      assert {:ok, doc} =
               run_changes(
                 "abc123",
                 [
                   edit("hello"),
                   edit("world")
                 ],
                 version: 2
               )

      assert "world" == text(doc)
      assert 2 = doc.version
    end

    test "starting a document" do
      assert {:ok, doc} =
               run_changes("", [
                 edit("document", new_range(0, 0, 1, 0))
               ])

      assert "document" = text(doc)
    end

    test "incrementally removing content" do
      hello_world = "function abc() {\n  console.log(\"hello, world!\");\n}"

      assert {:ok, doc} =
               run_changes(hello_world, [
                 edit("", range_for_substring(hello_world, "hello, world!"))
               ])

      assert "function abc() {\n  console.log(\"\");\n}" = text(doc)
    end

    test "incrementally removing multi-line content" do
      orig = "function abc() {\n  foo();\n  bar();\n  \n}"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("", range_for_substring(orig, "  foo();\n  bar();\n"))
               ])

      assert "function abc() {\n  \n}" = text(doc)
    end

    test "incrementally removing multi-line content 2" do
      orig = "function abc() {\n  foo();\n  bar();\n  \n}"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("", range_for_substring(orig, "foo();\n  bar();"))
               ])

      assert "function abc() {\n  \n  \n}" == text(doc)
    end

    test "incrementally adding content" do
      orig = "function abc() {\n  console.log(\"hello\");\n}"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit(", world!", range_after_substring(orig, "hello"))
               ])

      assert "function abc() {\n  console.log(\"hello, world!\");\n}" == text(doc)
    end

    test "incrementally adding multi-line content" do
      orig = "function abc() {\n  while (true) {\n    foo();\n  };\n}"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("\n    bar();", range_after_substring(orig, "foo();"))
               ])

      assert "function abc() {\n  while (true) {\n    foo();\n    bar();\n  };\n}" == text(doc)
    end

    test "incrementally replacing single-line content, more chars" do
      orig = "function abc() {\n  console.log(\"hello, world!\");\n}"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("hello, test case!!!", range_for_substring(orig, "hello, world!"))
               ])

      assert "function abc() {\n  console.log(\"hello, test case!!!\");\n}" == text(doc)
    end

    test "incrementally replacing single-line content, less chars" do
      orig = "function abc() {\n  console.log(\"hello, world!\");\n}"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("hey", range_for_substring(orig, "hello, world!"))
               ])

      assert "function abc() {\n  console.log(\"hey\");\n}" == text(doc)
    end

    test "incrementally replacing single-line content, same num of chars" do
      orig = "function abc() {\n  console.log(\"hello, world!\");\n}"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("world, hello!", range_for_substring(orig, "hello, world!"))
               ])

      assert "function abc() {\n  console.log(\"world, hello!\");\n}" == text(doc)
    end

    test "incrementally replacing multi-line content, more lines" do
      orig = "function abc() {\n  console.log(\"hello, world!\");\n}"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("\n//hello\nfunction d(){", range_for_substring(orig, "function abc() {"))
               ])

      assert "\n//hello\nfunction d(){\n  console.log(\"hello, world!\");\n}" == text(doc)
    end

    test "incrementally replacing multi-line content, fewer lines" do
      orig = "a1\nb1\na2\nb2\na3\nb3\na4\nb4\n"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("xx\nyy", range_for_substring(orig, "\na3\nb3\na4\nb4\n"))
               ])

      assert "a1\nb1\na2\nb2xx\nyy" == text(doc)
    end

    test "incrementally replacing multi-line content, same num of lines and chars" do
      orig = "a1\nb1\na2\nb2\na3\nb3\na4\nb4\n"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("\nxx1\nxx2", range_for_substring(orig, "a2\nb2\na3"))
               ])

      assert "a1\nb1\n\nxx1\nxx2\nb3\na4\nb4\n" = text(doc)
    end

    test "incrementally replacing multi-line content, same num of lines but diff chars" do
      orig = "a1\nb1\na2\nb2\na3\nb3\na4\nb4\n"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("\ny\n", range_for_substring(orig, "a2\nb2\na3"))
               ])

      assert "a1\nb1\n\ny\n\nb3\na4\nb4\n" == text(doc)
    end

    test "incrementally replacing multi-line content, huge number of lines" do
      orig = "a1\ncc\nb1"
      text = for _ <- 1..20_000, into: "", do: "\ndd"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit(text, range_for_substring(orig, "\ncc"))
               ])

      assert "a1" <> text <> "\nb1" == text(doc)
    end

    test "several incremental content changes" do
      orig = "function abc() {\n  console.log(\"hello, world!\");\n}"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("defg", new_range(0, 12, 0, 12)),
                 edit("hello, test case!!!", new_range(1, 15, 1, 28)),
                 edit("hij", new_range(0, 16, 0, 16))
               ])

      assert "function abcdefghij() {\n  console.log(\"hello, test case!!!\");\n}" = text(doc)
    end

    test "basic append" do
      orig = "foooo\nbar\nbaz"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit(" some extra content", new_range(1, 3, 1, 3))
               ])

      assert "foooo\nbar some extra content\nbaz" == text(doc)
    end

    test "multi-line append" do
      orig = "foooo\nbar\nbaz"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit(" some extra\ncontent", new_range(1, 3, 1, 3))
               ])

      assert "foooo\nbar some extra\ncontent\nbaz" == text(doc)
    end

    test "basic delete" do
      orig = "foooo\nbar\nbaz"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("", new_range(1, 0, 1, 3))
               ])

      assert "foooo\n\nbaz" = text(doc)
    end

    test "multi-line delete" do
      orig = "foooo\nbar\nbaz"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("", new_range(0, 5, 1, 3))
               ])

      assert "foooo\nbaz" == text(doc)
    end

    test "single character replace" do
      orig = "foooo\nbar\nbaz"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("z", new_range(1, 2, 1, 3))
               ])

      assert "foooo\nbaz\nbaz" == text(doc)
    end

    test "multi-character replace" do
      orig = "foo\nbar"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("foobar", new_range(1, 0, 1, 3))
               ])

      assert "foo\nfoobar" == text(doc)
    end

    test "windows line endings are preserved in document" do
      orig = "foooo\r\nbar\rbaz"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("z", new_range(1, 2, 1, 3))
               ])

      assert "foooo\r\nbaz\rbaz" == text(doc)
    end

    test "windows line endings are preserved in inserted text" do
      orig = "foooo\nbar\nbaz"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("z\r\nz\rz", new_range(1, 2, 1, 3))
               ])

      assert "foooo\nbaz\r\nz\rz\nbaz" == text(doc)
    end

    test "utf8 glyphs are preserved in document" do
      orig = "foooo\nb🏳️‍🌈r\nbaz"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("z", new_range(1, 7, 1, 8))
               ])

      assert "foooo\nb🏳️‍🌈z\nbaz" == text(doc)
    end

    test "utf8 glyphs are preserved in inserted text" do
      orig = "foooo\nbar\nbaz"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("z🏳️‍🌈z", new_range(1, 2, 1, 3))
               ])

      assert "foooo\nbaz🏳️‍🌈z\nbaz" == text(doc)
    end

    test "works with a content change event" do
      orig = """
      defmodule LanguageServer.Experimental.Expert.Test do
        def foo do
          {"🎸",    "other"}
        end
      end
      """

      event =
        edit(
          "",
          %Range{
            start: %Position{character: 0, line: 2},
            end: %Position{character: 22, line: 2}
          }
        )

      assert {:ok, doc} = run_changes(orig, [event])
      assert {:ok, ""} = fetch_text_at(doc, 3)
    end

    test "deleting a line with a multi-byte character" do
      orig = """
      defmodule LanguageServer.Experimental.Expert.Test do
        def foo do
          {"🎸", "other"}
        end
      end
      """

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("", new_range(2, 0, 2, 19))
               ])

      {:ok, line} = fetch_text_at(doc, 3)
      assert line == ""
    end

    test "inserting a line with unicode" do
      orig = """
      defmodule MyModule do
        def func do

        end
      end
      """

      assert {:ok, doc} =
               run_changes(orig, [
                 edit(~s(    {"🎸",   "ok"}), new_range(2, 0, 2, 0)),
                 edit("", new_range(2, 11, 2, 13))
               ])

      {:ok, line} = fetch_text_at(doc, 3)

      assert line == "    {\"🎸\", \"ok\"}"
    end

    test "invalid update range - before the document starts -> before the document starts" do
      orig = "foo\nbar"
      invalid_range = new_range(-2, 0, -1, 3)

      assert {:error, {:invalid_range, ^invalid_range}} =
               run_changes(orig, [
                 edit("abc123", new_range(-2, 0, -1, 3))
               ])
    end

    test "invalid update range - before the document starts -> the middle of document" do
      orig = "foo\nbar"
      invalid_range = new_range(-1, 0, 0, 3)

      assert {:error, {:invalid_range, ^invalid_range}} =
               run_changes(orig, [
                 edit("foobar", new_range(-1, 0, 0, 3))
               ])
    end

    test "invalid update range - the middle of document -> after the document ends" do
      orig = "foo\nbar"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("foobar", new_range(1, 0, 1, 10))
               ])

      assert "foo\nfoobar" == text(doc)
    end

    test "invalid update range - after the document ends -> after the document ends" do
      orig = "foo\nbar"

      assert {:ok, doc} =
               run_changes(orig, [
                 edit("abc123", new_range(3, 0, 6, 10))
               ])

      assert "foo\nbarabc123" == text(doc)
    end

    test "invalid update range - before the document starts -> after the document ends" do
      orig = "foo\nbar"
      invalid_range = new_range(-1, 1, 2, 10_000)

      assert {:error, {:invalid_range, ^invalid_range}} =
               run_changes(orig, [
                 edit("entirely new content", invalid_range)
               ])
    end
  end

  def document(text) do
    new(file_uri(), String.trim(text), 0)
  end

  describe "fragment/2" do
    test "works with out of bounds lines" do
      doc =
        """
        one
        two
        three
        """
        |> document()
        |> Document.fragment(new_position(3, 0))

      assert "one\ntwo\nthree" == doc
    end

    test "can omit entire lines" do
      doc =
        """
        one
        two
        three
        """
        |> document()
        |> Document.fragment(new_position(2, 0))

      assert "one\ntwo\n" == doc
    end

    test "can truncate the end of a line" do
      doc =
        """
        one
        two
        three
        """
        |> document()
        |> Document.fragment(new_position(2, 2))

      assert "one\ntwo\nth" == doc
    end
  end

  describe "fragment/3" do
    test "can omit an entire line" do
      doc =
        """
        one
        two
        three
        """
        |> document()
        |> Document.fragment(new_position(1, 0), new_position(3, 0))

      assert "two\nthree" == doc
    end

    test "can truncate the beginning of a line" do
      doc =
        """
        one
        two
        three
        """
        |> document()
        |> Document.fragment(new_position(0, 2), new_position(3, 0))

      assert "e\ntwo\nthree" == doc
    end

    test "can truncate both the beginning and end of a line" do
      doc =
        """
        one
        two
        three
        """
        |> document()
        |> Document.fragment(new_position(0, 2), new_position(1, 1))

      assert "e\nt" == doc
    end

    test "works if the start line is the end line" do
      doc =
        "this is the first line\nthis is the second"
        |> document()
        |> Document.fragment(
          %Position{line: 0, character: 5},
          %Position{line: 0, character: 7}
        )

      assert doc == "is"
    end
  end
end
