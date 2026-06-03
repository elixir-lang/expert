defmodule Engine.Build.Document.Compilers.QuotedTest do
  use ExUnit.Case, async: true

  import Forge.Test.CodeSigil

  alias Engine.Build.Document.Compilers.Quoted
  alias Forge.Document

  defmodule ProjectStackSentinel do
    def project do
      [app: :project_stack_sentinel, version: "0.1.0"]
    end
  end

  defp parse!(code) do
    Code.string_to_quoted!(code, columns: true, token_metadata: true)
  end

  describe "wrap_top_level_forms/1" do
    test "chunks and wraps unsafe top-level forms" do
      quoted =
        ~q[
          foo = 1
          bar = foo + 1

          import Something

          defmodule MyModule do
            :ok
          end

          baz = bar + foo
        ]
        |> parse!()

      assert quoted |> Quoted.wrap_top_level_forms() |> Macro.to_string() == """
             defmodule :expert_wrapper_0 do
               def __expert_wrapper__([]) do
                 foo = 1
                 _ = foo + 1
               end
             end

             import Something

             defmodule MyModule do
               :ok
             end

             defmodule :expert_wrapper_2 do
               def __expert_wrapper__([foo, bar]) do
                 _ = bar + foo
               end
             end\
             """
    end
  end

  describe "compile/3" do
    test "skips mix.exs without popping the current Mix project" do
      Mix.ProjectStack.on_clean_slate(fn ->
        Mix.Project.push(ProjectStackSentinel, "/tmp/project/mix.exs", :project_stack_sentinel)

        quoted =
          """
          defmodule Other.MixProject do
            use Mix.Project

            def project do
              [app: :other, version: "0.1.0"]
            end
          end
          """
          |> parse!()

        document = Document.new("file:///tmp/project/mix.exs", Macro.to_string(quoted), 0)

        assert {:ok, []} = Quoted.compile(document, quoted, "Elixir")
        assert Mix.Project.get() == ProjectStackSentinel
      end)
    end
  end

  describe "suppress_and_extract_vars/1" do
    test "suppresses and extracts unused vars" do
      quoted =
        ~q[
          foo = 1
          bar = 2
        ]
        |> parse!()

      assert {suppressed, [{:foo, _, nil}, {:bar, _, nil}]} =
               Quoted.suppress_and_extract_vars(quoted)

      assert Macro.to_string(suppressed) == """
             _ = 1
             _ = 2\
             """
    end

    test "suppresses and extracts unused vars in nested assignments" do
      quoted =
        ~q[
          foo = bar = 1
          baz = qux = 2
        ]
        |> parse!()

      assert {suppressed, [{:foo, _, nil}, {:bar, _, nil}, {:baz, _, nil}, {:qux, _, nil}]} =
               Quoted.suppress_and_extract_vars(quoted)

      assert Macro.to_string(suppressed) == """
             _ = _ = 1
             _ = _ = 2\
             """
    end

    test "suppresses vars only referenced in RHS" do
      quoted = ~q[foo = foo + 1] |> parse!()

      assert {suppressed, [{:foo, _, nil}]} = Quoted.suppress_and_extract_vars(quoted)

      assert Macro.to_string(suppressed) == "_ = foo + 1"
    end

    test "suppresses deeply nested vars" do
      quoted = ~q[{foo, {bar, %{baz: baz}}} = call()] |> parse!()

      assert {suppressed, [{:baz, _, nil}, {:bar, _, nil}, {:foo, _, nil}]} =
               Quoted.suppress_and_extract_vars(quoted)

      assert Macro.to_string(suppressed) == "{_, {_, %{baz: _}}} = call()"
    end

    test "does not suppress vars referenced in a later expression" do
      quoted =
        ~q[
          foo = 1
          bar = foo + 1
        ]
        |> parse!()

      assert {suppressed, [{:foo, _, nil}, {:bar, _, nil}]} =
               Quoted.suppress_and_extract_vars(quoted)

      assert Macro.to_string(suppressed) == """
             foo = 1
             _ = foo + 1\
             """
    end

    test "does not suppress vars referenced with pin operator in a later assignment" do
      quoted =
        ~q[
          foo = 1
          %{^foo => 2} = call()
        ]
        |> parse!()

      assert {suppressed, [{:foo, _, nil}]} = Quoted.suppress_and_extract_vars(quoted)

      assert Macro.to_string(suppressed) == """
             foo = 1
             %{^foo => 2} = call()\
             """
    end
  end
end
