defmodule Engine.Build.ErrorTest do
  alias Engine.Build
  alias Engine.Build.CaptureServer
  alias Engine.ModuleMappings
  alias Forge.Document
  require Logger

  import Forge.Test.DiagnosticSupport
  import Forge.Test.RangeSupport
  use ExUnit.Case
  use Patch

  setup do
    start_supervised!(Engine.Dispatch)
    start_supervised!(CaptureServer)
    :ok
  end

  def compile(source) do
    doc = Document.new("file:///unknown.ex", source, 0)
    Build.Document.compile(doc)
  end

  def diagnostics({:error, diagnostics}) do
    diagnostics
  end

  def diagnostic({:error, [diagnostic]}) do
    diagnostic
  end

  def diagnostic({:ok, [diagnostic]}) do
    diagnostic
  end

  describe "refine_diagnostics/1" do
    test "normalizes the message when its a iodata" do
      diagnostic = %Mix.Task.Compiler.Diagnostic{
        file: "lib/dummy.ex",
        severity: :warning,
        message: [
          ":slave.stop/1",
          " is deprecated. ",
          "It will be removed in OTP 27. Use the 'peer' module instead"
        ],
        position: 6,
        compiler_name: "Elixir",
        details: nil
      }

      [normalized] = Build.Error.refine_diagnostics([diagnostic])

      assert normalized.message ==
               ":slave.stop/1 is deprecated. It will be removed in OTP 27. Use the 'peer' module instead"

      assert String.starts_with?(normalized.uri, "file://")
      assert String.ends_with?(normalized.uri, "lib/dummy.ex")
    end
  end

  describe "diagnostic/3" do
    setup do
      patch(ModuleMappings, :modules_in_file, fn _ -> [] end)
      :ok
    end

    @feature_condition span_in_diagnostic?: false
    @tag execute_if(@feature_condition)
    test "handles undefined variable" do
      document_text = ~S[
        defmodule Foo do
          def bar do
            a
          end
        end
      ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message in [~s[undefined variable "a"], ~s[undefined function a/0]]
      assert decorate(document_text, diagnostic.position) =~ "«a\n»"
    end

    @feature_condition span_in_diagnostic?: true
    @tag execute_if(@feature_condition)
    test "handles undefined variable when #{inspect(@feature_condition)}" do
      document_text = ~S[
        defmodule Foo do
          def bar do
            a
          end
        end
      ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message == ~s[undefined variable "a"]
      assert decorate(document_text, diagnostic.position) =~ "«a»"
    end

    @feature_condition span_in_diagnostic?: false
    @tag execute_if(@feature_condition)
    test "handles unused variable warning" do
      document_text = ~S[
        defmodule Foo do
          def bar do
            a = 1
          end
        end
      ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~ ~s[variable "a" is unused]
      assert decorate(document_text, diagnostic.position) =~ "«a = 1\n»"
    end

    @feature_condition span_in_diagnostic?: true
    @tag execute_if(@feature_condition)
    test "handles unused variable warning when #{inspect(@feature_condition)}" do
      document_text = ~S[
        defmodule Foo do
          def bar do
            a = 1
          end
        end
      ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message == ~s[variable "a" is unused]
      assert decorate(document_text, diagnostic.position) =~ "«a»"
    end

    @feature_condition span_in_diagnostic?: false
    @tag execute_if(@feature_condition)
    test "handles unused function warning" do
      document_text = ~S[
        defmodule UnusedDefp do
          defp unused do
          end
        end
      ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.uri
      assert diagnostic.severity == :warning
      assert diagnostic.message =~ ~S[function unused/0 is unused]
      assert decorate(document_text, diagnostic.position) =~ "«defp unused do\n»"
    end

    @feature_condition span_in_diagnostic?: true
    @tag execute_if(@feature_condition)
    test "handles unused function warning when #{inspect(@feature_condition)}" do
      document_text = ~S[
        defmodule UnusedDefp do
          defp unused do
          end
        end
      ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.uri
      assert diagnostic.severity == :warning
      assert diagnostic.message =~ ~S[function unused/0 is unused]
      assert decorate(document_text, diagnostic.position) =~ "«unused do\n»"
    end

    test "handles FunctionClauseError" do
      document_text = ~S[
        defmodule Foo do
          def add(a, b) when is_integer(a) and is_integer(b) do
            a + b
          end
        end

        Foo.add("1", "2")
      ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~ ~s[no function clause matching in Foo.add/2]

      assert decorate(document_text, diagnostic.position) =~
               "«def add(a, b) when is_integer(a) and is_integer(b) do\n»"
    end

    test "handles UndefinedError for erlang module" do
      document_text = ~S[
        defmodule Foo do
         :slave.stop
        end
      ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~ ~s[function :slave.stop/0 is undefined or private.]
      assert decorate(document_text, diagnostic.position) =~ ":slave.«stop\n»"
    end

    test "handles UndefinedError for erlang function without defined module" do
      document_text = ~S[

         :slave.stop(:name, :name)
        ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~ ~s[function :slave.stop/2 is undefined or private.]
      assert decorate(document_text, diagnostic.position) =~ ":slave.«stop(:name, :name)\n»"
      assert diagnostic.position == {3, 17}
    end

    @feature_condition span_in_diagnostic?: false
    @tag execute_if(@feature_condition)
    test "handles UndefinedError" do
      document_text = ~S[
        defmodule Foo do
          def bar do
            print(:bar)
          end
        end
      ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~
               ~s[undefined function print/1]

      assert decorate(document_text, diagnostic.position) =~ "«print(:bar)\n»"
    end

    @feature_condition span_in_diagnostic?: true
    @tag execute_if(@feature_condition)
    test "handles UndefinedError when #{inspect(@feature_condition)}" do
      document_text = ~S[
        defmodule Foo do
          def bar do
            print(:bar)
          end
        end
      ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~
               ~s[undefined function print/1]

      assert decorate(document_text, diagnostic.position) =~ "«print»(:bar)"
    end

    @feature_condition span_in_diagnostic?: false
    @tag execute_if(@feature_condition)
    test "handles multiple UndefinedError in one line" do
      document_text = ~S/
        defmodule Foo do
          def bar do
            [print(:bar), a, b]
          end
        end
      /

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message in [~s[undefined function print/1], ~s[undefined function a/0]]
      assert decorate(document_text, diagnostic.position) =~ "«[print(:bar), a, b]\n»"
    end

    @feature_condition span_in_diagnostic?: true
    @tag execute_if(@feature_condition)
    test "handles multiple UndefinedError in one line when #{inspect(@feature_condition)}" do
      document_text = ~S/
        defmodule Foo do
          def bar do
            [print(:bar), a, b]
          end
        end
      /

      diagnostics =
        document_text
        |> compile()
        |> diagnostics()

      [func_diagnostic, b, a] =
        case diagnostics do
          [func_diagnostic, b, a] ->
            [func_diagnostic, b, a]

          [b, a] ->
            [nil, b, a]
        end

      assert a.message == ~s[undefined variable "a"]
      assert decorate(document_text, a.position) =~ "«a»"

      assert b.message == ~s[undefined variable "b"]
      assert decorate(document_text, b.position) =~ "«b»"

      if func_diagnostic do
        assert func_diagnostic.message == ~s[undefined function print/1]
        assert decorate(document_text, func_diagnostic.position) =~ "«print»(:bar)"
      end
    end

    test "handles UndefinedError without module" do
      document_text = ~S[

          IO.ins
        ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~ ~s[function IO.ins/0 is undefined or private]
      assert decorate(document_text, diagnostic.position) =~ "IO.«ins\n»"
    end

    @feature_condition with_diagnostics?: false
    @tag execute_if(@feature_condition)
    test "handles ArgumentError" do
      diagnostics =
        ~s[String.to_integer ""]
        |> compile()
        |> diagnostics()

      [diagnostic | _] = diagnostics

      assert diagnostic.message =~
               "the call to String.to_integer/1 will fail with ArgumentError"
    end

    @feature_condition with_diagnostics?: true
    @tag execute_if(@feature_condition)
    test "handles ArgumentError when #{inspect(@feature_condition)}" do
      diagnostics =
        ~s[String.to_integer ""]
        |> compile()
        |> diagnostics()

      [diagnostic | _] = diagnostics

      assert diagnostic.message =~ ~s[errors were found at the given arguments:]
    end

    test "handles ArgumentError when in module" do
      document_text = ~s[
        defmodule Foo do
          :a |> {1, 2}
        end
      ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~
               ~s[cannot pipe :a into {1, 2}, can only pipe into local calls foo()]

      assert decorate(document_text, diagnostic.position) =~ "«:a |> {1, 2}\n»"
    end

    test "handles ArgumentError when in function" do
      document_text = ~s[
        defmodule Foo do
          def foo do
            :a |> {1, 2}
          end
        end
      ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~
               ~s[cannot pipe :a into {1, 2}, can only pipe into local calls foo()]

      assert decorate(document_text, diagnostic.position) =~ "«:a |> {1, 2}\n»"
    end

    test "can't find right line when use macro" do
      diagnostic =
        ~S[
          Module.create(
            Foo,
            quote do
              String.to_integer("")
            end,
            file: "")
      ]
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~ ~s[errors were found at the given arguments:]
      assert diagnostic.position == nil
    end

    test "handles Protocol.UndefinedError for comprehension" do
      document_text = ~S[
        defmodule Foo do
          for i <- 1, do: i
        end]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      # used a regex here because the error changed in elixir 1.18
      assert diagnostic.message =~
               ~r[protocol Enumerable not implemented for( 1 of)?( type)? Integer]

      assert decorate(document_text, diagnostic.position) =~ "«for i <- 1, do: i\n»"
    end

    test "handles Protocol.UndefinedError for comprehension when no module" do
      document_text = ~S[
          for i <- 1, do: i
        ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      # used a regex here because the error changed in elixir 1.18
      assert diagnostic.message =~
               ~r[protocol Enumerable not implemented for( 1 of)?( type)? Integer]

      assert decorate(document_text, diagnostic.position) =~ "«for i <- 1, do: i\n»"
    end

    test "handles RuntimeError" do
      document_text = ~S[defmodule Foo do
        raise RuntimeError.exception("This is a runtime error")
      end
      ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~
               ~s[This is a runtime error]

      assert decorate(document_text, diagnostic.position) =~ "«defmodule Foo do\n»"
    end

    test "handles ExUnit.DuplicateTestError" do
      document_text = ~s[
        defmodule FooTest do
          use ExUnit.Case, async: true

          test "foo" do
            assert 1 == 1
          end

          test "foo" do
            assert 1 == 1
          end
        end
        ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~ ~s[\"test foo\" is already defined in FooTest]
      assert decorate(document_text, diagnostic.position) =~ "«test \"foo\" do\n»"
    end

    test "handles ExUnit.DuplicateDescribeError" do
      document_text = ~s[

        defmodule FooTest do
          use ExUnit.Case, async: true

          describe "foo" do
            test "foo" do
              assert 1 == 1
            end
          end

          describe "foo" do
            test "foo" do
              assert 1 == 1
            end
          end
        end
        ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~ ~s[describe \"foo\" is already defined in FooTest]
      assert decorate(document_text, diagnostic.position) =~ "«describe \"foo\" do\n»"
    end

    test "handles struct `KeyError` when is in a function block" do
      document_text = ~s(
        defmodule Foo do
          defstruct [:a, :b]
        end

        defmodule Bar do
          def bar do
            %Foo{c: :value}
          end
        end
        )

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~ "key :c not found"
      assert decorate(document_text, diagnostic.position) =~ "«%Foo{c: :value}\n»"
    end

    @feature_condition span_in_diagnostic?: false
    @tag execute_if(@feature_condition)
    test "handles struct `CompileError` when is in a function params" do
      document_text = ~S/
        defmodule Foo do
          defstruct [:a, :b]
        end

        defmodule Bar do
          def bar(%Foo{c: c}) do
          end
        end
        /

      diagnostics =
        document_text
        |> compile()
        |> diagnostics()

      [diagnostic] = diagnostics
      assert diagnostic.message =~ "unknown key :c for struct Foo"

      if Features.with_diagnostics?() do
        assert decorate(document_text, diagnostic.position) =~ "def bar(«%Foo{c: c}) do\n»"
      else
        assert decorate(document_text, diagnostic.position) =~ "«def bar(%Foo{c: c}) do\n»"
      end
    end

    @feature_condition span_in_diagnostic?: true
    @tag execute_if(@feature_condition)
    test "handles struct `CompileError` when is in a function params and #{inspect(@feature_condition)}" do
      document_text = ~S/
        defmodule Foo do
          defstruct [:a, :b]
        end

        defmodule Bar do
          def bar(%Foo{c: c}) do
          end
        end
        /

      [undefined, unknown] =
        document_text
        |> compile()
        |> diagnostics()

      assert unknown.message == "unknown key :c for struct Foo"
      assert decorate(document_text, unknown.position) =~ "def bar(«%Foo{c: c}) do\n»"

      assert undefined.message == "variable \"c\" is unused"
      assert decorate(document_text, undefined.position) =~ "def bar(%Foo{c: «c»}) do"
    end

    test "handles struct enforce key error" do
      document_text = ~s(
        defmodule Foo do
          @enforce_keys [:a, :b]
          defstruct [:a, :b]
        end

        defmodule Bar do
          def bar do
            %Foo{}
          end
        end
        )

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~
               "the following keys must also be given when building struct Foo: [:a, :b]"

      assert decorate(document_text, diagnostic.position) =~ "«%Foo{}\n»"
    end

    test "handles record missing key's error" do
      document_text = ~s[
        defmodule Bar do
          import Record
          defrecord :user, name: nil, age: nil

          def bar do
            u = user(name: "John", email: "")
          end
        end
        ]

      diagnostic =
        document_text
        |> compile()
        |> diagnostic()

      assert diagnostic.message =~
               "record :user does not have the key: :email"

      assert decorate(document_text, diagnostic.position) =~
               "«u = user(name: \"John\", email: \"\")\n»"
    end
  end
end
