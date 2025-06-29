defmodule Engine.CompletionTest do
  alias Engine.Completion
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Document

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures
  import Forge.Test.Quiet

  use ExUnit.Case, async: true
  use Patch

  describe "struct_fields/2" do
    test "returns the field completion for current module" do
      source = ~q<
        defmodule Project.Issue do
          defstruct [:message]
          @type t :: %__MODULE__{|}
        end
      >

      [message] = struct_fields(source)
      assert message.name == :message
    end

    test "returns the field completions for aliased module" do
      source = ~q<
        defmodule Project.Issue do
          alias Project.Issue
          defstruct [:message]
          @type t :: %Issue{|}
        end
      >

      [message] = struct_fields(source)
      assert message.name == :message
    end

    test "returns [] when cursor is not in a struct" do
      source = ~q<
        defmodule Project.Issue do
          alias Project.Issue
          defstruct [:message]
          @type t :: %Issue{}|
        end
      >

      assert struct_fields(source) == []
    end

    test "returns the field completions when cursor is in the current module child's arguments" do
      source = ~q<
        defmodule Project do
          defmodule Issue do
            @type t :: %Issue{}
            defstruct [:message]
          end

          def message(%__MODULE__.Issue{|} = issue) do
            issue.message
          end
        end
      >

      [message] = struct_fields(source)
      assert message.name == :message
    end

    test "returns the field completion when cursor is in an alias child's arguments" do
      source = ~q<
        defmodule Project do
          defmodule Issue do
            defstruct [:message]
          end
        end

        defmodule MyModule do
          alias Project

          def message(%Project.Issue{|} = issue) do
            issue.message
          end
        end
      >

      [message] = struct_fields(source)
      assert message.name == :message
    end
  end

  def expose_strip_struct_operator(_) do
    Patch.expose(Completion, strip_struct_operator: 1)
    :ok
  end

  describe "strip_struct_operator/1" do
    setup [:expose_strip_struct_operator]

    test "with a reference followed by  __" do
      {doc, _position} =
        "%__"
        |> new_env()
        |> private(Completion.strip_struct_operator())

      assert doc == "__"
    end

    test "with a reference followed by a module name" do
      {doc, _position} =
        "%Module"
        |> new_env()
        |> private(Completion.strip_struct_operator())

      assert doc == "Module"
    end

    test "with a reference followed by a module and a dot" do
      {doc, _position} =
        "%Module."
        |> new_env()
        |> private(Completion.strip_struct_operator())

      assert doc == "Module."
    end

    test "with a reference followed by a nested module" do
      {doc, _position} =
        "%Module.Sub"
        |> new_env()
        |> private(Completion.strip_struct_operator())

      assert doc == "Module.Sub"
    end

    test "with a reference followed by an alias" do
      code = ~q[
        alias Something.Else
        %El|
      ]t

      {doc, _position} =
        code
        |> new_env()
        |> private(Completion.strip_struct_operator())

      assert doc == "alias Something.Else\nEl"
    end

    test "on a line with two references, replacing the first" do
      {doc, _position} =
        "%First{} = %Se"
        |> new_env()
        |> private(Completion.strip_struct_operator())

      assert doc == "%First{} = Se"
    end

    test "on a line with two references, replacing the second" do
      {doc, _position} =
        "%Fir| = %Second{}"
        |> new_env()
        |> private(Completion.strip_struct_operator())

      assert doc == "Fir = %Second{}"
    end

    test "with a plain module" do
      env = new_env("Module")
      {doc, _position} = private(Completion.strip_struct_operator(env))

      assert doc == Document.to_string(env.document)
    end

    test "with a plain module strip_struct_reference a dot" do
      env = new_env("Module.")
      {doc, _position} = private(Completion.strip_struct_operator(env))

      assert doc == Document.to_string(env.document)
    end

    test "leaves leading spaces in place" do
      {doc, _position} =
        "     %Some"
        |> new_env()
        |> private(Completion.strip_struct_operator())

      assert doc == "     Some"
    end

    test "works in a function definition" do
      {doc, _position} =
        "def my_function(%Lo|)"
        |> new_env()
        |> private(Completion.strip_struct_operator())

      assert doc == "def my_function(Lo)"
    end
  end

  defp struct_fields(source) do
    {position, document} = pop_cursor(source, as: :document)
    text = Document.to_string(document)

    quiet(:stderr, fn ->
      Code.compile_string(text)
    end)

    analysis =
      document
      |> Ast.analyze()
      |> Ast.reanalyze_to(position)

    Completion.struct_fields(analysis, position)
  end

  def new_env(text) do
    project = project()
    {position, document} = pop_cursor(text, as: :document)
    analysis = Ast.analyze(document)
    {:ok, env} = Env.new(project, analysis, position)
    env
  end
end
