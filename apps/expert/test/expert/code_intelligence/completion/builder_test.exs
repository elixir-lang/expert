defmodule Expert.CodeIntelligence.Completion.BuilderTest do
  alias Expert.CodeIntelligence.Completion.SortScope
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Protocol.Convertible
  alias GenLSP.Structures.CompletionItem

  use ExUnit.Case, async: true

  import Expert.CodeIntelligence.Completion.Builder
  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures

  def new_env(text) do
    project = project()
    {position, document} = pop_cursor(text, as: :document)
    analysis = Ast.analyze(document)
    {:ok, env} = Env.new(project, analysis, position)
    env
  end

  def item(label, opts \\ []) do
    fields = Keyword.merge(opts, label: label)

    CompletionItem
    |> struct(fields)
    |> set_sort_scope(SortScope.default())
  end

  defp sort_items(items) do
    Enum.sort_by(items, &{&1.sort_text, &1.label})
  end

  setup do
    start_supervised!(Expert.Application.document_store_child_spec())
    :ok
  end

  describe "sort scopes" do
    test "scope order follows module -> variable -> local -> remote -> global -> auto -> default" do
      i = set_sort_scope(item("g"), SortScope.module())
      ii = set_sort_scope(item("f"), SortScope.variable())
      iii = set_sort_scope(item("e"), SortScope.local())
      iv = set_sort_scope(item("d"), SortScope.remote())
      v = set_sort_scope(item("c"), SortScope.global())
      vi = set_sort_scope(item("b"), SortScope.auto())
      vii = set_sort_scope(item("a"), SortScope.default())

      assert [^i, ^ii, ^iii, ^iv, ^v, ^vi, ^vii] = sort_items([vii, vi, v, iv, iii, ii, i])
    end

    test "low priority sorts items lower in their scope" do
      alpha_first = set_sort_scope(item("a"), SortScope.remote(false, 2))
      alpha_second = set_sort_scope(item("b"), SortScope.remote())
      alpha_third = set_sort_scope(item("c"), SortScope.remote())

      assert [^alpha_second, ^alpha_third, ^alpha_first] =
               sort_items([alpha_first, alpha_second, alpha_third])
    end

    test "deprecated items are gathered at the bottom of their scope" do
      i_deprecated = set_sort_scope(item("a"), SortScope.remote(true))
      i = set_sort_scope(item("a"), SortScope.remote())
      ii = set_sort_scope(item("b"), SortScope.remote())
      iii_low = set_sort_scope(item("c"), SortScope.remote(false, 2))

      assert [^i, ^ii, ^iii_low, ^i_deprecated] = sort_items([i_deprecated, i, ii, iii_low])
    end
  end

  describe "snippet edge cases" do
    # The following would crash due to missing case clauses
    # in `prefix_length/1`
    test "handles aliases inside locals" do
      "before __MODULE__.Submodule|"
      |> new_env()
      |> snippet("", label: "")
    end

    test "handles locals inside a module attribute" do
      "@hello.Submodule"
      |> new_env()
      |> snippet("", label: "")
    end
  end

  describe "non-ascii line range clamp" do
    test "plain_text clamps start_char >= 1 and serializes on non-ASCII line" do
      doc = Document.new("file:///builder_test.ex", "⚠️ hello", 0)
      pos = Position.new(doc, 1, 1)

      env = %Env{document: doc, position: pos, prefix: "a"}

      item = plain_text(env, "X", label: "X")

      assert {:ok, lsp_text_edit_or_list} = Convertible.to_lsp(item.text_edit)

      lsp_edits = List.wrap(lsp_text_edit_or_list)

      refute Enum.empty?(lsp_edits)

      for %{range: %{start: %{character: start_ch}, end: %{character: end_ch}}} <- lsp_edits do
        assert start_ch == 0
        assert end_ch == 0
      end
    end

    test "snippet clamps start_char >= 1 and serializes on non-ASCII line" do
      doc = Document.new("file:///builder_test.ex", "⚠️ hello", 0)
      pos = Position.new(doc, 1, 1)

      env = %Env{document: doc, position: pos, prefix: "a"}

      item = snippet(env, "X$0", label: "X")

      assert {:ok, lsp_text_edit_or_list} = Convertible.to_lsp(item.text_edit)

      lsp_edits = List.wrap(lsp_text_edit_or_list)

      refute Enum.empty?(lsp_edits)

      for %{range: %{start: %{character: start_ch}, end: %{character: end_ch}}} <- lsp_edits do
        assert start_ch == 0
        assert end_ch == 0
      end
    end
  end
end
