defmodule Engine.Build.Document.Compilers.HeexTest do
  alias Engine.Build
  alias Engine.Build.CaptureServer
  alias Engine.Build.Document.Compilers
  alias Engine.Dispatch
  alias Engine.ModuleMappings
  alias Forge.Document
  alias Forge.Plugin.V1.Diagnostic.Result

  import Forge.Test.CodeSigil
  import Forge.Test.Quiet
  use ExUnit.Case

  def with_capture_server(_) do
    start_supervised!(CaptureServer)
    start_supervised!(Dispatch)
    start_supervised!(ModuleMappings)
    :ok
  end

  def document_with_content(content) do
    Document.new("file:///file.heex", content, 0)
  end

  setup_all do
    prev_compiler_options = Code.compiler_options()
    Build.State.set_compiler_options()

    on_exit(fn ->
      Code.compiler_options(prev_compiler_options)
    end)
  end

  def compile(document) do
    quiet(:stderr, fn ->
      Compilers.HEEx.compile(document)
    end)
  end

  describe "compile/1" do
    setup [:with_capture_server]

    test "handles valid HEEx content" do
      document = document_with_content(~q[
        <div>thing</div>
      ])
      assert {:ok, _} = compile(document)
    end

    test "ignore undefined assigns" do
      document = document_with_content(~q[
        <div><%= @thing %></div>
      ])

      assert {:error, []} = compile(document)
    end

    test "handles undefined variables" do
      document = document_with_content(~q[
        <div><%= thing %></div>
      ])

      assert {:error, [%Result{} = result]} = compile(document)

      if Features.with_diagnostics?() do
        assert result.message =~ ~S[undefined variable "thing"]
      else
        assert result.message =~ "undefined function thing/0"
        assert result.position in [1, {1, 10}]
        assert result.severity == :error
        assert result.source == "EEx"
      end
    end

    test "shouldn't report errors if the variable is defined with :let " do
      document = document_with_content(~q|
          <.form
            :let={f}
            phx-change="change_name"
          >
            <.inputs_for :let={f_nested} field={f[:nested]}>
              <.input type="text" field={f_nested[:name]} />
              <%= f_nested %>
            </.inputs_for>
          </.form>
        |)

      if Features.with_diagnostics?() do
        assert {:error, []} = compile(document)
      else
        # we don't want to ignore the undefined function error when Elixir < 1.15
        assert {:error, [_]} = compile(document)
      end
    end

    test "returns error when there are unclosed tags" do
      document = document_with_content(~q[
        <div>thing
      ])
      assert {:error, [%Result{} = result]} = compile(document)

      assert result.message =~
               "end of template reached without closing tag for <div>\n  |\n1 | <div>thing\n  | ^"

      assert result.position == {1, 1}
      assert result.severity == :error
      assert result.source == "HEEx"
      assert result.uri =~ "file:///file.heex"
    end

    test "returns error when HEEx syntax is invalid" do
      document = document_with_content(~q[
        <span id=@id}></span>
      ])

      assert {:error, [%Result{} = result]} = compile(document)

      assert result.message =~ "invalid attribute value after `=`. "
      assert result.position == {1, 10}
      assert result.severity == :error
      assert result.source == "HEEx"
      assert result.uri =~ "file:///file.heex"
    end

    test "handles EEx syntax error" do
      document = document_with_content(~q[
        <%= IO.
      ])
      assert {:error, [%Result{} = result]} = compile(document)

      assert result.message =~ "'%>'"
      assert result.source == "EEx"
    end
  end
end
