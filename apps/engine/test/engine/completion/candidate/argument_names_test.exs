defmodule Forge.Completion.Candidate.ArgumentNamesTest do
  alias Forge.Completion.Candidate.ArgumentNames

  use ExUnit.Case
  import ArgumentNames

  describe "parsing elixir sense argument names" do
    test "handles normal arguments" do
      assert ~w(first second third) == from_elixir_sense(~w(first second third), 3)
    end

    test "handles default arguments in the first position" do
      args = ["first \\\\ 3", "second", "third"]

      assert ~w(second third) == from_elixir_sense(args, 2)
      assert ~w(first second third) == from_elixir_sense(args, 3)
    end

    test "handles default arguments in the middle" do
      args = ["first", "second \\\\", "third"]

      assert ~w(first third) = from_elixir_sense(args, 2)
      assert ~w(first second third) = from_elixir_sense(args, 3)
    end

    test "handles default arguments at the last position" do
      args = ["first", "second", "third \\\\ 3"]

      assert ~w(first second) = from_elixir_sense(args, 2)
      assert ~w(first second third) = from_elixir_sense(args, 3)
    end

    test "handles multiple default arguments" do
      args = ["first", "second \\\\ 1", "third", "fourth \\\\ 2", "fifth \\\\ 3", "sixth"]

      assert ~w(first third sixth) = from_elixir_sense(args, 3)
      assert ~w(first second third sixth) = from_elixir_sense(args, 4)
      assert ~w(first second third fourth sixth) = from_elixir_sense(args, 5)
      assert ~w(first second third fourth fifth sixth) = from_elixir_sense(args, 6)
    end

    test "handles struct defaults" do
      args = ["first", "second \\\\ %Struct{}", "third"]

      assert ~w(first third) = from_elixir_sense(args, 2)
      assert ~w(first second third) = from_elixir_sense(args, 3)
    end

    test "handles match arguments with structs" do
      assert ~w(project) = from_elixir_sense(["%Project{} = project"], 1)
      assert ~w(project) = from_elixir_sense(["project = %Project{}"], 1)
      assert ~w(arg_1) = from_elixir_sense(["%Project{}"], 1)
    end

    test "handles match arguments with lists" do
      assert ~w(items) = from_elixir_sense(["[a, b, c] = items"], 1)
      assert(~w(items) = from_elixir_sense(["items = [a, b, c]"], 1))
      assert ~w(arg_1) = from_elixir_sense(["[a, b, c]"], 1)
    end

    test "handles match arguments with tuples" do
      assert ~w(items) = from_elixir_sense(["{a, b, c = items"], 1)
      assert(~w(items) = from_elixir_sense(["items = {a, b, c}"], 1))
      assert ~w(arg_1) = from_elixir_sense(["{a, b, c}"], 1)
    end

    test "handles empty arguments" do
      assert ["foo", ""] == from_elixir_sense(["foo", ""], 2)
    end

    test "handles incorrect arity" do
      args = ~w(first second third)
      assert :error == from_elixir_sense(args, 1)
      assert :error == from_elixir_sense(args, 2)
      assert :error == from_elixir_sense(args, 4)
    end

    test "handles atoms in names" do
      # Note: having a raw atom in there crashed ArgumentNames before
      assert ~w(handlerId :level level) = from_elixir_sense(~w(handlerId :level level), 3)
    end
  end
end
