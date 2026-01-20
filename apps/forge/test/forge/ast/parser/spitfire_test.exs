defmodule Forge.Ast.Parser.SpitfireTest do
  use ExUnit.Case, async: false
  use Patch

  import ExUnit.CaptureLog

  alias Forge.Ast.Parser.Spitfire

  describe "string_to_quoted/1" do
    test "returns {:ok, ast, comments} for valid code" do
      assert {:ok, ast, comments} = Spitfire.string_to_quoted("defmodule Foo do end")
      assert {:defmodule, _, _} = ast
      assert is_list(comments)
    end

    test "returns {:error, ast, error, comments} for code with syntax errors" do
      assert {:error, _ast, _error, _comments} = Spitfire.string_to_quoted("defmodule Foo do")
    end

    test "returns error tuple when parser crashes" do
      # Patch the Spitfire library module (not our wrapper)
      patch(Elixir.Spitfire, :parse_with_comments, fn _string, _opts ->
        raise CaseClauseError, term: :identifier
      end)

      log =
        capture_log(fn ->
          result = Spitfire.string_to_quoted("some code")

          assert {:error, {[line: 1, column: 1], message}, []} = result
          assert message =~ "parser crashed"
          assert message =~ "no case clause matching"
        end)

      assert log =~
               "Spitfire parser crashed: ** (CaseClauseError) no case clause matching: :identifier"
    end
  end

  describe "container_cursor_to_quoted/1" do
    test "returns {:ok, ast} for valid fragment" do
      assert {:ok, _ast} = Spitfire.container_cursor_to_quoted("defmodule Foo do\n  ")
    end

    test "returns error tuple when parser crashes" do
      patch(Elixir.Spitfire, :container_cursor_to_quoted, fn _fragment, _opts ->
        raise CaseClauseError, term: :identifier
      end)

      log =
        capture_log(fn ->
          result = Spitfire.container_cursor_to_quoted("some fragment")

          assert {:error, {[line: 1, column: 1], message}} = result
          assert message =~ "parser crashed"
          assert message =~ "no case clause matching"
        end)

      assert log =~
               "Spitfire parser crashed: ** (CaseClauseError) no case clause matching: :identifier"
    end
  end
end
