defmodule Engine.RenameTest do
  use ExUnit.Case, async: true

  import Forge.Test.CodeSigil
  import Forge.Test.Fixtures
  import Forge.Test.RangeSupport

  alias Engine.Rename
  alias Forge.Document
  alias Forge.Document.Changes
  alias Forge.Test.CodeMod.Case, as: CodeModCase

  setup do
    Engine.set_project(project())
    :ok
  end

  defp rename_at(code, new_name) do
    {range, code} = pop_range(code)
    document = Document.new("file:///file.ex", code, 0)
    position = range.start

    case Rename.rename(document, position, new_name) do
      {:ok, nil} -> {:ok, nil}
      {:ok, %Changes{edits: edits}} -> {:ok, CodeModCase.apply_edits(code, edits, [])}
    end
  end

  describe "rename variable" do
    test "renames all occurrences of a local variable" do
      assert {:ok, result} =
               rename_at(
                 ~q[
                   def my_func do
                     «»value = 42
                     value + value
                   end
                 ],
                 "number"
               )

      assert result =~ "number = 42"
      assert result =~ "number + number"
      refute result =~ ~r/\bvalue\b/
    end
  end

  describe "rename function" do
    test "renames a function definition and its local calls" do
      assert {:ok, result} =
               rename_at(
                 ~q[
                   defmodule MyMod do
                     def «»old_name(x), do: x + 1

                     def caller, do: old_name(10)
                   end
                 ],
                 "new_name"
               )

      assert result =~ "def new_name"
      assert result =~ "new_name(10)"
      refute result =~ ~r/\bold_name\b/
    end
  end

  describe "rename constant" do
    test "renames a module attribute constant and its references" do
      assert {:ok, result} =
               rename_at(
                 ~q[
                   defmodule MyMod do
                     @«»old_const 42

                     def get, do: @old_const
                   end
                 ],
                 "new_const"
               )

      assert result =~ "@new_const 42"
      assert result =~ "@new_const"
      refute result =~ ~r/@old_const/
    end
  end

  describe "rename guard" do
    test "renames a guard implementation and its call sites" do
      assert {:ok, result} =
               rename_at(
                 ~q[
                   defmodule MyMod do
                     defguard «»is_positive(x) when x > 0

                     def check(x) when is_positive(x), do: :ok
                   end
                 ],
                 "is_gt_zero"
               )

      assert result =~ "is_gt_zero"
      assert result =~ "def check(x) when is_gt_zero(x)"
    end
  end

  describe "rename unavailable" do
    test "returns nil when cursor is not on a renameable symbol" do
      assert {:ok, nil} =
               rename_at(
                 ~q[
                   def my_func do
                     «»42
                   end
                 ],
                 "new_name"
               )
    end
  end
end
