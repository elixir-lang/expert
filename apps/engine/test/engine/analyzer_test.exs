defmodule Engine.AnalyzerTest do
  alias Engine.Analyzer
  alias Forge.Ast
  alias Forge.Ast.Analysis

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport

  use ExUnit.Case, async: true

  describe "current_module/2" do
    test "fails if there is not __MODULE__ defined" do
      {position, document} =
        ~q[x
          |defmodule Outer do
          end
        ]
        |> pop_cursor(as: :document)

      analysis = Ast.analyze(document)
      assert :error = Analyzer.current_module(analysis, position)
    end

    test "fails in a defmodule call if there is no containing module" do
      {position, document} =
        ~q[
          defmodule| Outer do
          end
        ]
        |> pop_cursor(as: :document)

      analysis = Ast.analyze(document)
      assert :error = Analyzer.current_module(analysis, position)
    end

    test "returns the current module right after the do" do
      {position, document} =
        ~q[
          defmodule Outer do|
          end
        ]
        |> pop_cursor(as: :document)

      analysis = Ast.analyze(document)
      assert {:ok, Outer} = Analyzer.current_module(analysis, position)
    end

    test "returns the parent module in the child's defmodule" do
      {position, document} =
        ~q[
          defmodule Parent do
            defmodule Child| do
            end
          end
        ]
        |> pop_cursor(as: :document)

      analysis = Ast.analyze(document)
      assert {:ok, Parent} = Analyzer.current_module(analysis, position)
    end

    test "returns a nested module in the child's module" do
      {position, document} =
        ~q[
          defmodule Parent do
            defmodule Child do|
            end
          end
        ]
        |> pop_cursor(as: :document)

      analysis = Ast.analyze(document)
      assert {:ok, Parent.Child} = Analyzer.current_module(analysis, position)
    end

    test "works in a protocol definition" do
      {position, document} =
        ~q[
          defprotocol MyProtocol do
            def something(data)|
          end
        ]
        |> pop_cursor(as: :document)

      analysis = Ast.analyze(document)
      assert {:ok, MyProtocol} = Analyzer.current_module(analysis, position)
    end
  end

  describe "expand_alias/4" do
    test "works with aliased modules" do
      {position, document} =
        ~q[
          defmodule Parent do
            alias Foo.Bar.Something
            |
          end
        ]
        |> pop_cursor(as: :document)

      analysis = Ast.analyze(document)

      assert {:ok, Foo.Bar.Something.Baz} =
               Analyzer.expand_alias([:Something, :Baz], analysis, position)
    end

    test "works with protocol definitions nested in a module" do
      {position, document} =
        ~q[
          defmodule Parent do
            alias Foo.Bar.Something
            alias Foo.Bar.Protocol
            defimpl  |Protocol, for: Something do
            end
          end
        ]
        |> pop_cursor(as: :document)

      analysis = Ast.analyze(document)

      assert {:ok, Foo.Bar.Protocol} = Analyzer.expand_alias([:Protocol], analysis, position)
      assert {:ok, Foo.Bar.Something} = Analyzer.expand_alias([:Something], analysis, position)
      assert {:ok, Parent} = Analyzer.expand_alias([:__MODULE__], analysis, position)
    end

    test "works with protocol with aliased protocol and target" do
      {position, document} =
        ~q[
          alias Foo.Bar.Something
          alias Foo.Bar.Protocol
          defimpl Protocol, for: Something do
            @test true|
          end
        ]
        |> pop_cursor(as: :document)

      analysis = Ast.analyze(document)

      assert {:ok, Foo.Bar.Protocol} = Analyzer.expand_alias([:Protocol], analysis, position)

      assert {:ok, Foo.Bar.Protocol} =
               Analyzer.expand_alias(quote(do: [@protocol]), analysis, position)

      assert {:ok, Foo.Bar.Something} = Analyzer.expand_alias([:Something], analysis, position)

      assert {:ok, Foo.Bar.Something} =
               Analyzer.expand_alias(quote(do: [@for]), analysis, position)

      assert {:ok, Foo.Bar.Protocol.Foo.Bar.Something} =
               Analyzer.expand_alias([:__MODULE__], analysis, position)
    end

    test "works with __MODULE__ aliases" do
      {position, document} =
        ~q[
          defmodule Parent do
            defmodule __MODULE__.Child do
              |
            end
          end
        ]
        |> pop_cursor(as: :document)

      analysis = Ast.analyze(document)

      assert {:ok, Parent.Child} =
               Analyzer.expand_alias([quote(do: __MODULE__), nil], analysis, position)
    end

    test "works with @protocol in a protocol" do
      {position, document} =
        ~q[
        defimpl MyProtocol, for: Atom do

          def pack(atom) do
            |
          end
        end
        ]
        |> pop_cursor(as: :document)

      analysis = Ast.analyze(document)

      assert {:ok, MyProtocol} = Analyzer.expand_alias([quote(do: @protocol)], analysis, position)

      assert {:ok, MyProtocol.BitString} =
               Analyzer.expand_alias([quote(do: @protocol.BitString)], analysis, position)

      assert {:ok, Atom} = Analyzer.expand_alias([quote(do: @for)], analysis, position)

      assert {:ok, Atom.Something} =
               Analyzer.expand_alias([quote(do: @for.Something)], analysis, position)

      assert {:ok, MyProtocol.BitString} =
               Analyzer.expand_alias(
                 [
                   {:@, [line: 9, column: 8], [{:protocol, [line: 9, column: 9], nil}]},
                   :BitString
                 ],
                 analysis,
                 position
               )
    end

    test "identifies the module in a protocol implementation" do
      {position, document} =
        ~q[
          defimpl MyProtocol, for: Atom do

            def pack(atom) do
              |
            end
          end
        ]
        |> pop_cursor(as: :document)

      analysis = Ast.analyze(document)
      assert {:ok, MyProtocol.Atom} == Analyzer.current_module(analysis, position)
    end
  end

  describe "reanalyze_to/2" do
    test "is a no-op if the analysis is already valid" do
      {position, document} =
        ~q[
          defmodule Valid do
            |
          end
        ]
        |> pop_cursor(as: :document)

      assert %Analysis{valid?: true} = analysis = Ast.analyze(document)
      assert analysis == Ast.reanalyze_to(analysis, position)
    end

    test "returns a valid analysis if fragment can be parsed" do
      {position, document} =
        ~q[
          defmodule Invalid do
            |
        ]
        |> pop_cursor(as: :document)

      assert %Analysis{valid?: false} = analysis = Ast.analyze(document)
      assert %Analysis{valid?: true} = analysis = Ast.reanalyze_to(analysis, position)
      assert {:ok, Invalid} = Analyzer.current_module(analysis, position)
    end
  end
end
