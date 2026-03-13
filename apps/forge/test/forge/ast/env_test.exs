defmodule Forge.Ast.EnvTest do
  use ExUnit.Case, async: true

  import Forge.Ast.Env
  import Forge.Test.CursorSupport

  alias Forge.Ast
  alias Forge.Project

  def new_env(text, opts \\ []) do
    opts = Keyword.merge([as: :document], opts)
    project = Project.new("file://#{File.cwd!()}")
    {position, document} = pop_cursor(text, opts)
    analysis = Ast.analyze(document)
    {:ok, env} = new(project, analysis, position)
    env
  end

  describe "prefix_tokens/2" do
    test "works with bitstring specifiers" do
      env = new_env("<<foo::int|")

      assert [{:identifier, ~c"int", _}, {:operator, :"::", _}] = prefix_tokens(env, 2)
    end

    test "works with floats" do
      tokens =
        "27.88"
        |> new_env()
        |> prefix_tokens(1)

      assert [{:float, 27.88, _}] = tokens
    end

    test "works with strings" do
      tokens =
        ~s("hello")
        |> new_env()
        |> prefix_tokens(1)

      assert [{:string, "hello", _}] = tokens
    end

    test "works with interpolated strings" do
      tokens =
        ~S("hello#{a}")
        |> new_env()
        |> prefix_tokens(1)

      assert [{:interpolated_string, interpolations, {1, 1}}] = tokens

      assert interpolations == [
               {:literal, "hello", {{1, 1}, {1, 6}}},
               {:interpolation, [{:identifier, {1, 9, ~c"a"}, :a}], {{1, 9}, {1, 10}}}
             ]
    end

    test "works with maps with atom keys" do
      tokens =
        "%{a: 3}"
        |> new_env()
        |> prefix_tokens(9)

      assert [
               {:curly, :"}", _},
               {:int, 3, _},
               {:kw_identifier, ~c"a", _},
               {:curly, :"{", _},
               {:map_new, :%{}, _}
             ] = tokens
    end

    test "works with maps with string keys" do
      tokens =
        ~s(%{"a" => 3})
        |> new_env()
        |> prefix_tokens(8)

      assert [
               {:curly, :"}", _},
               {:int, 3, _},
               {:assoc_op, nil, _},
               {:string, "a", _},
               {:curly, :"{", _},
               {:map_new, :%{}, _}
             ] = tokens
    end

    test "works with pattern matches" do
      tokens =
        "my_var = 3 + 5"
        |> new_env()
        |> prefix_tokens(3)

      assert [
               {:int, 5, _},
               {:operator, :+, _},
               {:int, 3, _}
             ] = tokens
    end

    test "works with remote function calls" do
      tokens =
        "Enum.map|"
        |> new_env()
        |> prefix_tokens(9)

      assert [
               {:identifier, ~c"map", _},
               {:operator, :., _},
               {:alias, ~c"Enum", _}
             ] = tokens
    end

    test "works with local function calls" do
      tokens =
        "foo = local(|"
        |> new_env()
        |> prefix_tokens(9)

      assert [
               {:paren, :"(", _},
               {:paren_identifier, ~c"local", _},
               {:match_op, nil, _},
               {:identifier, ~c"foo", _}
             ] = tokens
    end

    test "consumes as many tokens as it can" do
      tokens =
        "String.tri|"
        |> new_env()
        |> prefix_tokens(900)

      assert [
               {:identifier, ~c"tri", _},
               {:operator, :., _},
               {:alias, ~c"String", _}
             ] = tokens
    end

    test "works with macros" do
      tokens =
        "defmacro MyModule do"
        |> new_env()
        |> prefix_tokens(3)

      assert [
               {:operator, :do, _},
               {:alias, ~c"MyModule", _},
               {:identifier, ~c"defmacro", _}
             ] = tokens
    end

    test "works with lists of integers" do
      tokens =
        "x = [1, 2, 3]"
        |> new_env()
        |> prefix_tokens(7)

      assert [
               {:operator, :"]", _},
               {:int, 3, _},
               {:comma, :",", _},
               {:int, 2, _},
               {:comma, :",", _},
               {:int, 1, _},
               {:operator, :"[", _}
             ] = tokens
    end
  end

  describe "in_context?/2" do
    test "can detect module attributes" do
      env = new_env("@my_attr 3")

      assert in_context?(env, {:module_attribute, :my_attr})
      refute in_context?(env, {:module_attribute, :other})
    end

    test "can detect behaviours" do
      env = new_env("@behaviour Modul|e")

      assert in_context?(env, :behaviour)
    end

    test "can detect behaviour implementations" do
      env = new_env("@impl GenServer|")

      assert in_context?(env, :impl)
    end

    test "can detect docstrings " do
      env = new_env("@doc false|")
      assert in_context?(env, :doc)

      env = new_env(~S[@doc "hi"])
      assert in_context?(env, :doc)

      env = new_env(~S[@doc """
      Multi - line
      """|
      ])
      assert in_context?(env, :doc)
    end

    test "can detect moduledocs " do
      env = new_env("@moduledoc false|")
      assert in_context?(env, :moduledoc)

      env = new_env(~S[@moduledoc "hi"])
      assert in_context?(env, :moduledoc)

      env = new_env(~S[@moduledoc """
      Multi - line
      """|
      ])
      assert in_context?(env, :moduledoc)
    end

    test "can detect callbacks" do
      env = new_env("@callback do_stuff|(integer(), map()) :: any()")
      assert in_context?(env, :callback)
    end

    test "can detect macro callbacks" do
      env = new_env("@macrocallback write_code(integer(), map(|)) :: any()")
      assert in_context?(env, :macrocallback)
    end

    test "can detect strings" do
      env = new_env(~s/var = "in |a string"/)
      assert in_context?(env, :string)
    end
  end
end
