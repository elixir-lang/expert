defmodule Engine.CodeMod.DiffTest do
  alias Engine.CodeMod.Diff
  alias Forge.Document
  alias Forge.Document.Edit
  alias Forge.Document.Range

  use Forge.Test.CodeMod.Case
  use Forge.Test.PositionSupport

  def edit(start_line, start_code_unit, end_line, end_code_unit, replacement) do
    Edit.new(
      replacement,
      Range.new(
        position(start_line, start_code_unit),
        position(end_line, end_code_unit)
      )
    )
  end

  def apply_code_mod(source, _, opts) do
    document = Document.new("file:///file.ex", source, 1)
    result = Keyword.get(opts, :result)
    {:ok, Diff.diff(document, result)}
  end

  def assert_edited(initial, final) do
    assert {:ok, edited} = modify(initial, result: final, convert_to_ast: false)
    assert edited == final
  end

  defp diff(original, modified) do
    document = Document.new("file://file.ex", original, 0)
    Diff.diff(document, modified)
  end

  describe "single line ascii diffs" do
    test "a deletion at the start" do
      orig = "  hello"
      final = "hello"

      assert [edit] = diff(orig, final)
      assert_normalized(edit == edit(1, 1, 1, 3, ""))
      assert_edited(orig, final)
    end

    test "appending in the middle" do
      orig = "hello"
      final = "heyello"

      assert [edit] = diff(orig, final)
      assert_normalized(edit == edit(1, 3, 1, 3, "ye"))
      assert_edited(orig, final)
    end

    test "deleting in the middle" do
      orig = "hello"
      final = "heo"

      assert [edit] = diff(orig, final)
      assert_normalized(edit == edit(1, 3, 1, 5, ""))
      assert_edited(orig, final)
    end

    test "inserting after a delete" do
      orig = "hello"
      final = "helvetica went"

      # this is collapsed into a single edit of an
      # insert that spans the delete and the insert
      assert [edit] = diff(orig, final)
      assert_normalized(edit == edit(1, 4, 1, 6, "vetica went"))
      assert_edited(orig, final)
    end

    test "edits are ordered back to front on a line" do
      orig = "hello there"
      final = "hellothe"

      assert [e1, e2] = diff(orig, final)
      assert_normalized(e1 == edit(1, 10, 1, 12, ""))
      assert_normalized(e2 == edit(1, 6, 1, 7, ""))
    end
  end

  describe "applied edits" do
    test "multiple edits on the same line don't conflict" do
      orig = "foo(   a,   b)"
      expected = "foo(a, b)"

      assert_edited(orig, expected)
    end
  end

  describe "multi line ascii diffs" do
    test "multi-line deletion at the start" do
      orig =
        """
        none
        two
        hello
        """
        |> String.trim()

      final = "hello"

      assert [edit] = diff(orig, final)
      assert_normalized(edit == edit(1, 1, 3, 1, ""))
      assert_edited(orig, final)
    end

    test "multi-line appending in the middle" do
      orig = "hello"
      final = "he\n\n ye\n\nllo"

      assert [edit] = diff(orig, final)
      assert_normalized(edit == edit(1, 3, 1, 3, "\n\n ye\n\n"))
      assert_edited(orig, final)
    end

    test "deleting multiple lines in the middle" do
      orig =
        """
        hello
        there
        people
        goodbye
        """
        |> String.trim()

      final = "hellogoodbye"

      assert [edit] = diff(orig, final)
      assert_normalized(edit == edit(1, 6, 4, 1, ""))
      assert_edited(orig, final)
    end

    test "deleting multiple lines" do
      orig = ~q[
        foo(a,
          b,
          c,
          d)
      ]

      final = ~q[
        foo(a, b, c, d)
      ]t

      assert_edited(orig, final)
    end

    test "deletions keep indentation" do
      orig =
        """
        hello
        there


          people
        """
        |> String.trim()

      final =
        """
        hello
        there
          people
        """
        |> String.trim()

      assert [edit] = diff(orig, final)
      assert_normalized(edit == edit(3, 1, 5, 1, ""))
      assert_edited(orig, final)
    end
  end

  describe "single line emoji" do
    test "deleting after" do
      orig = ~S[{"🎸",   "after"}]
      final = ~S[{"🎸", "after"}]

      assert [edit] = diff(orig, final)
      assert_normalized(edit == edit(1, 10, 1, 12, ""))
      assert_edited(orig, final)
    end

    test "inserting in the middle" do
      orig = ~S[🎸🎸]
      final = ~S[🎸🎺🎸]

      assert [edit] = diff(orig, final)
      assert_normalized(edit == edit(1, 5, 1, 5, "🎺"))
      assert_edited(orig, final)
    end

    test "deleting in the middle" do
      orig = ~S[🎸🎺🎺🎸]
      final = ~S[🎸🎸]

      assert [edit] = diff(orig, final)
      assert_normalized(edit == edit(1, 5, 1, 13, ""))
      assert_edited(orig, final)
    end

    test "multiple deletes on the same line" do
      orig = ~S[🎸a 🎺b 🎺c 🎸]
      final = ~S[🎸ab🎸]

      assert_edited(orig, final)
    end
  end

  describe("multi line emoji") do
    test "deleting on the first line" do
      orig = ~q[
        🎸a 🎺b 🎺c 🎸
        hello
      ]t

      final = ~q[
        🎸a b c 🎸
        hello
      ]t

      assert_edited(orig, final)
    end

    test "deleting on subsequent lines" do
      orig = ~q[
        🎸a 🎺b 🎺c 🎸
        hello
        🎸a 🎺b 🎺c 🎸
      ]t
      final = ~q[
        🎸a 🎺b 🎺c 🎸
        ello
        🎸a 🎺b 🎺c 🎸
      ]t

      assert_edited(orig, final)
    end
  end
end
