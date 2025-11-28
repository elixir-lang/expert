defmodule Engine.Build.Document.Compilers.EExTest do
  alias Engine.Build
  alias Engine.Build.CaptureServer
  alias Engine.Build.Document.Compilers
  alias Engine.Dispatch
  alias Engine.ModuleMappings
  alias Forge.Document
  alias Forge.Plugin.V1.Diagnostic.Result

  use ExUnit.Case

  import Compilers.EEx, only: [recognizes?: 1]
  import Forge.Test.Quiet
  import Forge.Test.CodeSigil
  import Forge.Test.DiagnosticSupport
  import Forge.Test.RangeSupport

  def with_capture_server(_) do
    start_supervised!(CaptureServer)
    start_supervised!(Dispatch)
    start_supervised!(ModuleMappings)
    :ok
  end

  def document_with_extension(extension) do
    Document.new("file:///file#{extension}", "", 0)
  end

  def document_with_content(content) do
    Document.new("file:///file.eex", content, 0)
  end

  def compile(document) do
    quiet(:stderr, fn -> Compilers.EEx.compile(document) end)
  end

  setup_all do
    prev_compiler_options = Code.compiler_options()
    Build.State.set_compiler_options()

    on_exit(fn ->
      Code.compiler_options(prev_compiler_options)
    end)
  end

  describe "recognizes?/1" do
    test "is true for .eex files" do
      assert recognizes?(document_with_extension(".eex"))
      assert recognizes?(document_with_extension(".html.eex"))
      assert recognizes?(document_with_extension(".js.eex"))
    end

    test "is false for elixir files" do
      refute recognizes?(document_with_extension(".ex"))
      refute recognizes?(document_with_extension(".exs"))
    end

    test "is false for other file types" do
      refute recognizes?(document_with_extension(".html"))
      refute recognizes?(document_with_extension(".js"))
      refute recognizes?(document_with_extension(".lock"))
    end
  end

  describe "eex_to_quoted/1" do
    setup [:with_capture_server]

    test "handles syntax errors" do
      {:error, [%Result{} = result]} =
        ~q[
        <%=
        ]t
        |> document_with_content()
        |> compile()

      # this assert is the best we can do; the error differs on different elixir versions
      assert result.message =~ "'%>'"
      assert {1, column} = result.position
      # The error's column differs on different elixir versions.
      assert column == 1 or column == 4
      assert result.severity == :error
      assert result.source == "EEx"
      assert result.uri
    end
  end

  describe "compile_quoted/2" do
    setup [:with_capture_server]

    @feature_condition span_in_diagnostic?: false
    @tag execute_if(@feature_condition)
    test "handles unused variables" do
      assert {:ok, [%Result{} = result]} =
               ~q[
               <%= something = 6 %>
               ]
               |> document_with_content()
               |> compile()

      assert result.message =~ ~s["something" is unused]
      assert result.position in [1, {1, 5}]
      assert result.severity == :warning
      assert result.source == "EEx"
      assert result.uri =~ "file:///file.eex"
    end

    @feature_condition span_in_diagnostic?: true
    @tag execute_if(@feature_condition)
    test "handles unused variables when #{inspect(@feature_condition)}" do
      document =
        ~q[
               <%= something = 6 %>
               ]
        |> document_with_content()

      assert {:ok, [%Result{} = result]} = compile(document)

      assert result.message == ~s[variable "something" is unused]
      assert decorate(document, result.position) == "<%= «something» = 6 %>"
      assert result.severity == :warning
      assert result.source == "EEx"
      assert result.uri =~ "file:///file.eex"
    end
  end

  describe "eval_quoted/2" do
    test "handles undefined function" do
      document = document_with_content(~q[
        <%= IO.uts("thing") %>
      ])

      assert {:error, [%Result{} = result]} = compile(document)
      assert result.message =~ "function IO.uts/1 is undefined or private"
      assert result.position == {1, 8}
      assert result.severity == :error
      assert result.source == "EEx"
      assert result.uri =~ "file:///file.eex"
    end

    @feature_condition span_in_diagnostic?: false
    @tag execute_if(@feature_condition)
    test "handles undefined variable" do
      document = document_with_content(~q[
        <%= thing %>
      ])

      assert {:error, [%Result{} = result]} = compile(document)

      if Features.with_diagnostics?() do
        assert result.message =~ "undefined variable \"thing\""
      else
        assert result.message =~ "undefined function thing/0"
      end

      assert result.position in [1, {1, 5}]
      assert result.severity == :error
      assert result.source == "EEx"
      assert result.uri =~ "file:///file.eex"
    end

    @feature_condition span_in_diagnostic?: true
    @tag execute_if(@feature_condition)
    test "handles undefined variable when #{inspect(@feature_condition)}" do
      document = document_with_content(~q[
        <%= thing %>
      ])

      assert {:error, [%Result{} = result]} = compile(document)

      assert result.message == "undefined variable \"thing\""
      assert decorate(document, result.position) == "<%= «thing» %>"
      assert result.severity == :error
      assert result.source == "EEx"
      assert result.uri =~ "file:///file.eex"
    end
  end
end
