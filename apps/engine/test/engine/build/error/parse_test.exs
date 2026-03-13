defmodule Engine.Build.Error.ParseTest do
  use ExUnit.Case, async: true

  import Forge.Test.DiagnosticSupport
  import Forge.Test.RangeSupport

  alias Engine.Build
  alias Engine.Build.CaptureServer
  alias Engine.Dispatch
  alias Forge.Document
  alias Forge.Plugin.V1.Diagnostic

  setup do
    start_supervised!(Dispatch)
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

  describe "handling parse errors" do
    @feature_condition details_in_context?: false
    @tag execute_if(@feature_condition)
    test "handles token missing errors" do
      assert diagnostics =
               ~s[%{foo: 3]
               |> compile()
               |> diagnostics()

      [diagnostic] = diagnostics
      assert diagnostic.message =~ ~s[missing terminator: }]
      assert diagnostic.position == {1, 9}
    end

    @feature_condition details_in_context?: true, contains_set_theoretic_types?: false
    @tag execute_if(@feature_condition)
    test "handles token missing errors when #{inspect(@feature_condition)}" do
      document_text = ~s[%{foo: 3]

      assert [start_diagnostic, end_diagnostic] =
               document_text
               |> compile()
               |> diagnostics()

      assert start_diagnostic.message ==
               ~s[The `{` here is missing terminator `}`]

      assert decorate(document_text, start_diagnostic.position) == ~S[%«{»foo: 3]

      assert end_diagnostic.message == ~s[missing terminator: }]
      assert end_diagnostic.position == {1, 9}
    end

    @feature_condition contains_set_theoretic_types?: true
    @tag execute_if(@feature_condition)
    test "handles token missing errors when #{inspect(@feature_condition)}" do
      document_text = ~s[%{foo: 3]

      assert [start_diagnostic, end_diagnostic] =
               document_text
               |> compile()
               |> diagnostics()

      assert start_diagnostic.message ==
               ~s[The `{` here is missing terminator `}`]

      assert decorate(document_text, start_diagnostic.position) == ~S[«%»{foo: 3]

      assert end_diagnostic.message == ~s[missing terminator: }]
      assert end_diagnostic.position == {1, 9}
    end

    @feature_condition details_in_context?: false
    @tag execute_if(@feature_condition)
    test "returns both the error and the detail when provided" do
      errors =
        ~S[
        def handle_info(file_diagnostics(uri: uri, diagnostics: diagnostics), %State{} = state) do
        state = State.clear(state, uri)
        state = Enum.reduce(diagnostics, state, fn diagnostic, state ->
          case State.add(diagnostic, state, uri) do
            {:ok, new_state} ->
              new_state
            {:error, reason} ->
              Logger.error("Could not add diagnostic #{inspect(diagnostic)} because #{inspect(error)}")
              state
          end
        end

          publish_diagnostics(state)
        end
        ]
        |> compile()
        |> diagnostics()

      assert [start_diagnostic, end_diagnostic] = errors

      assert end_diagnostic.message =~ "unexpected reserved word: end"
      assert end_diagnostic.position == {15, 9}

      assert String.downcase(start_diagnostic.message) =~
               ~S[the "(" here is missing terminator ")"]

      assert start_diagnostic.position == 4
    end

    @feature_condition details_in_context?: true
    @tag execute_if(@feature_condition)
    test "returns both the error and the detail when provided and #{inspect(@feature_condition)}" do
      document_text = ~S[
        def handle_info(file_diagnostics(uri: uri, diagnostics: diagnostics), %State{} = state) do
        state = State.clear(state, uri)
        state = Enum.reduce(diagnostics, state, fn diagnostic, state ->
          case State.add(diagnostic, state, uri) do
            {:ok, new_state} ->
              new_state
            {:error, reason} ->
              Logger.error("Could not add diagnostic #{inspect(diagnostic)} because #{inspect(error)}")
              state
          end
        end

          publish_diagnostics(state)
        end
        ]

      errors =
        document_text
        |> compile()
        |> diagnostics()

      assert [start_diagnostic, end_diagnostic] = errors

      assert start_diagnostic.message == ~S[The `(` here is missing terminator `)`]

      assert decorate(document_text, start_diagnostic.position) =~
               ~S[Enum.reduce«(»diagnostics, state, fn diagnostic, state ->]

      assert end_diagnostic.message =~ "unexpected reserved word: end"
      assert end_diagnostic.position == {15, 9}
    end

    @feature_condition details_in_context?: false, with_diagnostics?: false
    @tag execute_if(@feature_condition)
    test "returns multiple diagnostics on the same line" do
      [end_diagnostic] =
        ~S{Keywor.get([], fn x -> )}
        |> compile()
        |> diagnostics()

      assert end_diagnostic.message =~ ~s[The \"fn\" here is missing terminator \"end\"]
      assert end_diagnostic.position == 1
    end

    @feature_condition details_in_context?: false, with_diagnostics?: true
    @tag execute_if(@feature_condition)
    test "returns multiple diagnostics on the same line when #{inspect(@feature_condition)}" do
      [end_diagnostic] =
        ~S{Keywor.get([], fn x -> )}
        |> compile()
        |> diagnostics()

      assert end_diagnostic.message =~ ~S[unexpected token: )]
      assert end_diagnostic.position == {1, 24}
    end

    @feature_condition details_in_context?: true
    @tag execute_if(@feature_condition)
    test "returns multiple diagnostics on the same line when #{inspect(@feature_condition)}" do
      document_text = ~S{Keywor.get([], fn x -> )}

      [start_diagnostic, end_diagnostic] =
        document_text
        |> compile()
        |> diagnostics()

      assert end_diagnostic.message == ~S[unexpected token: ), expected `end`]
      assert end_diagnostic.position == {1, 24}

      assert start_diagnostic.message == ~S[The `fn` here is missing terminator `end`]
      assert decorate(document_text, start_diagnostic.position) =~ ~S/Keywor.get([], «fn» x -> )/
    end

    @feature_condition details_in_context?: false
    @tag execute_if(@feature_condition)
    test "returns two diagnostics when missing end at the real end" do
      errors =
        ~S[
        defmodule Foo do
          def bar do
            :ok
        end]
        |> compile()
        |> diagnostics()

      assert [start_diagnostic, end_diagnostic] = errors

      assert %Diagnostic.Result{} = end_diagnostic
      assert end_diagnostic.message =~ "missing terminator: end"
      assert end_diagnostic.position == {5, 12}

      assert %Diagnostic.Result{} = start_diagnostic
      assert start_diagnostic.message == ~S[The `do` here is missing terminator `end`]
      assert start_diagnostic.position == 2
    end

    @feature_condition details_in_context?: true
    @tag execute_if(@feature_condition)
    test "returns two diagnostics when missing end at the real end and #{inspect(@feature_condition)}" do
      document_text = ~S[
        defmodule Foo do
          def bar do
            :ok
        end]

      errors =
        document_text
        |> compile()
        |> diagnostics()

      assert [start_diagnostic, end_diagnostic] = errors

      assert %Diagnostic.Result{} = end_diagnostic
      assert end_diagnostic.message == "missing terminator: end"
      assert end_diagnostic.position == {5, 12}

      assert %Diagnostic.Result{} = start_diagnostic
      assert start_diagnostic.message == ~S[The `do` here is missing terminator `end`]
      assert decorate(document_text, start_diagnostic.position) =~ ~S/defmodule Foo «do»/
    end

    test "returns the token in the message when encountering the `syntax error`" do
      diagnostic = ~S[1 + * 3] |> compile() |> diagnostic()
      assert diagnostic.message == "syntax error before: '*'"
      assert diagnostic.position == {1, 5}
    end

    @feature_condition details_in_context?: false
    @tag execute_if(@feature_condition)
    test "returns the approximate correct location when there is a hint." do
      diagnostics = ~S[
        defmodule Foo do
          def bar_missing_end do
            :ok

          def bar do
            :ok
          end
        end] |> compile() |> diagnostics()

      [start_diagnostic, hint_diagnostic, end_diagnostic] = diagnostics
      assert start_diagnostic.message == ~S[The `do` here is missing terminator `end`]
      assert start_diagnostic.position == 2
      assert end_diagnostic.message == ~S[missing terminator: end (for "do" starting at line 2)]
      assert end_diagnostic.position == {9, 12}

      assert hint_diagnostic.message ==
               ~S[HINT: it looks like the "do" here does not have a matching "end"]

      assert hint_diagnostic.position == 3
    end

    @feature_condition details_in_context?: true
    @tag execute_if(@feature_condition)
    test "returns the approximate correct location when there is a hint and #{inspect(@feature_condition)}" do
      document_text = ~S[
        defmodule Foo do
          def bar_missing_end do
            :ok

          def bar do
            :ok
          end
        end]

      diagnostics = document_text |> compile() |> diagnostics()

      [start_diagnostic, hint_diagnostic, end_diagnostic] = diagnostics

      assert start_diagnostic.message == ~S[The `do` here is missing terminator `end`]
      assert decorate(document_text, start_diagnostic.position) =~ ~S/defmodule Foo «do»/

      assert hint_diagnostic.message ==
               ~S[HINT: it looks like the "do" here does not have a matching "end"]

      assert hint_diagnostic.position == 3

      assert end_diagnostic.message == ~S[missing terminator: end]
      assert end_diagnostic.position == {9, 12}
    end

    @feature_condition details_in_context?: false
    @tag execute_if(@feature_condition)
    test "returns the last approximate correct location when there are multiple missing" do
      diagnostics = ~S[
        defmodule Foo do
          def bar_missing_end do
            :ok

          def bar_missing_end2 do

          def bar do
            :ok
          end
        end] |> compile() |> diagnostics()

      [start_diagnostic, hint_diagnostic, end_diagnostic] = diagnostics

      assert start_diagnostic.message == ~S[The `do` here is missing terminator `end`]
      assert start_diagnostic.position == 3

      assert hint_diagnostic.message ==
               ~S[HINT: it looks like the "do" here does not have a matching "end"]

      assert hint_diagnostic.position == 6

      assert end_diagnostic.message == ~S[missing terminator: end (for "do" starting at line 3)]
      assert end_diagnostic.position == {11, 12}
    end

    @feature_condition details_in_context?: true
    @tag execute_if(@feature_condition)
    test "returns the last approximate correct location when there are multiple missing and #{inspect(@feature_condition)}" do
      document_text = ~S[
        defmodule Foo do
          def bar_missing_end do
            :ok

          def bar_missing_end2 do

          def bar do
            :ok
          end
        end]

      [start_diagnostic, hint_diagnostic, end_diagnostic] =
        document_text |> compile() |> diagnostics()

      assert start_diagnostic.message == ~S[The `do` here is missing terminator `end`]
      assert decorate(document_text, start_diagnostic.position) =~ "def bar_missing_end «do»"

      assert hint_diagnostic.message ==
               ~S[HINT: it looks like the "do" here does not have a matching "end"]

      assert hint_diagnostic.position == 6

      assert end_diagnostic.message == ~S[missing terminator: end]
      assert end_diagnostic.position == {11, 12}
    end
  end
end
