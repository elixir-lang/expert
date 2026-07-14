defmodule Engine.CodeIntelligence.ReferencesTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures
  import Forge.Test.RangeSupport

  alias Engine.CodeIntelligence.References
  alias Engine.Search.Indexer.Source
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Document.Location

  setup do
    project = project()

    Engine.set_project(project)
    {:ok, store} = Agent.start_link(fn -> [] end)

    start_supervised!(Engine.ApplicationCache)
    start_supervised!(Document.Store)
    start_supervised!(Engine.Dispatch)

    patch(Engine.ManagerApi, :search_store_replace, fn ^project, entries ->
      Agent.update(store, fn _ -> entries end)
      :ok
    end)

    patch(Engine.ManagerApi, :search_store_exact, fn ^project, subject, constraints ->
      {:ok, query_entries(store, subject, constraints, :exact)}
    end)

    patch(Engine.ManagerApi, :search_store_prefix, fn ^project, subject, constraints ->
      {:ok, query_entries(store, subject, constraints, :prefix)}
    end)

    {:ok, project: project}
  end

  defp query_entries(store, subject, constraints, match_type) do
    type = Keyword.get(constraints, :type, :_)
    subtype = Keyword.get(constraints, :subtype, :_)
    subject = format_subject(subject)

    store
    |> Agent.get(& &1)
    |> Enum.filter(fn entry ->
      matches_constraint?(entry.type, type) and matches_constraint?(entry.subtype, subtype) and
        matches_subject?(format_subject(entry.subject), subject, match_type)
    end)
  end

  defp matches_subject?(entry_subject, subject, :exact), do: entry_subject == subject

  defp matches_subject?(entry_subject, subject, :prefix),
    do: String.starts_with?(entry_subject, subject)

  defp matches_constraint?(_value, :_), do: true
  defp matches_constraint?(value, value), do: true
  defp matches_constraint?(_, _), do: false

  defp format_subject(subject) when is_atom(subject), do: Forge.Formats.module(subject)
  defp format_subject(subject) when is_binary(subject), do: subject
  defp format_subject(subject), do: to_string(subject)

  defp module_uri(project) do
    project
    |> file_path(Path.join("lib", "my_module.ex"))
    |> Document.Path.ensure_uri()
  end

  defp project_module(project, content) do
    uri = module_uri(project)

    with :ok <- Document.Store.open(uri, content, 1) do
      Document.Store.fetch(uri)
    end
  end

  describe "function references" do
    test "are found inside public functions", %{project: project} do
      code = ~q/
        defmodule Functions do
          def func(x), do: Enum.map(x, & &1 + 1)
        end
      /
      assert [%Location{} = location] = references(project, "Enum.map|(a, b)", code)
      assert decorate(code, location.range) =~ "def func(x), do: «Enum.map(x, & &1 + 1)»"
    end

    test "are found inside private functions", %{project: project} do
      code = ~q/
        defmodule Functions do
          defp func(x), do: Enum.map(x, & &1 + 1)
        end
      /
      assert [%Location{} = location] = references(project, "Enum.map|(a, b)", code)
      assert decorate(code, location.range) =~ "defp func(x), do: «Enum.map(x, & &1 + 1)»"
    end

    test "are found in aliased functions", %{project: project} do
      code = ~q/
        defmodule Functions do
          alias Enum, as: E
          defp func(x), do: E.map(x, & &1 + 1)
        end
      /
      assert [%Location{} = location] = references(project, "Enum.map|(a, b)", code)
      assert decorate(code, location.range) =~ "defp func(x), do: «E.map(x, & &1 + 1)»"
    end

    test "are found in imported functions", %{project: project} do
      code = ~q/
        defmodule Functions do
          import Enum, only: [map: 2]
          defp func(x), do: map(x, & &1 + 1)
        end
      /
      assert [%Location{} = location] = references(project, "Enum.map|(a, b)", code)
      assert decorate(code, location.range) =~ "defp func(x), do: «map(x, & &1 + 1)»"
    end

    test "are found in local functions", %{project: project} do
      code = ~q/
        defmodule Functions do
          def do_map(a, b), do: Enum.map(a, b)

          def func(x), do: do_map(x, & &1 + 1)

        end
      /
      assert [%Location{} = location] = references(project, "Functions.do_map|(a, b)", code)
      assert decorate(code, location.range) =~ "def func(x), do: «do_map(x, & &1 + 1)»"
    end

    test "finds local and remote calls to the same function", %{project: project} do
      referenced = ~q/
        defmodule Functions do
          def do_map|(a, b), do: Enum.map(a, b)

          def local_call(x), do: do_map(x, & &1 + 1)
        end

        defmodule Caller do
          def remote_call(x), do: Functions.do_map(x, & &1 + 1)
        end
      /

      {_, code} = pop_cursor(referenced)

      references = references(project, referenced, code)

      assert [local, remote] = Enum.sort_by(references, & &1.range.start.line)
      assert decorate(code, local.range) =~ "def local_call(x), do: «do_map(x, & &1 + 1)»"

      assert decorate(code, remote.range) =~
               "def remote_call(x), do: «Functions.do_map(x, & &1 + 1)»"
    end

    test "are found in function definitions with optional arguments", %{project: project} do
      referenced = ~q/
      defmodule Functions do
        def do_map|(a, b, c \\ 3), do: {a, b, c}
        def func(x), do: do_map(x, 3, 5)
        def func2(x), do: do_map(x, 3)
      end
      /

      {_, code} = pop_cursor(referenced)

      references = references(project, referenced, code)
      assert [first, second] = Enum.sort_by(references, & &1.range.start.line)
      assert decorate(code, first.range) =~ "  def func(x), do: «do_map(x, 3, 5)»"
      assert decorate(code, second.range) =~ "  def func2(x), do: «do_map(x, 3)»"
    end
  end

  describe "module references" do
    test "are found in an alias", %{project: project} do
      code = ~q[
        defmodule ReferencesInAlias do
          alias ReferencedModule
        end
      ]

      assert [%Location{} = location] = references(project, "ReferencedModule|", code)
      assert decorate(code, location.range) =~ ~s[alias «ReferencedModule»]
    end

    test "are found in a module attribute", %{project: project} do
      code = ~q[
        defmodule ReferenceInAttribute do
          @attr ReferencedModule
        end
      ]

      assert [%Location{} = location] = references(project, "ReferencedModule|", code)
      assert decorate(code, location.range) =~ ~s[@attr «ReferencedModule»]
    end

    test "are found in a variable", %{project: project} do
      code = ~q[
        some_module = ReferencedModule
      ]

      assert [%Location{} = location] = references(project, "ReferencedModule|", code)
      assert decorate(code, location.range) =~ ~s[some_module = «ReferencedModule»]
    end

    test "are found in a function's parameters", %{project: project} do
      code = ~q[
        def some_fn(ReferencedModule) do
        end
      ]

      assert [%Location{} = location] = references(project, "ReferencedModule|", code)
      assert decorate(code, location.range) =~ ~s[def some_fn(«ReferencedModule») do]
    end

    test "includes struct definitions", %{project: project} do
      code = ~q[
        %ReferencedModule{} = something_else
      ]

      assert [%Location{} = location] = references(project, "ReferencedModule|", code)
      assert decorate(code, location.range) =~ ~s[%«ReferencedModule»{} = something_else]
    end

    test "includes definitions if the parameter is true", %{project: project} do
      code = ~q[
        defmodule DefinedModule do
        end

        defmodule OtherModule do
          @attr DefinedModule
        end
      ]

      assert [location_1, location_2] = references(project, "DefinedModule|", code, true)
      assert decorate(code, location_1.range) =~ ~s[defmodule «DefinedModule» do]
      assert decorate(code, location_2.range) =~ ~s[@attr «DefinedModule»]
    end
  end

  describe "struct references" do
    test "includes their definition if the parameter is true", %{project: project} do
      code = ~q(
      defmodule Struct do
        defstruct [:field]
      end
      )

      assert [location] = references(project, "%Struct|{}", code, true)
      assert decorate(code, location.range) =~ "«defstruct [:field]»"
    end

    test "includes references if defstruct is selected", %{project: project} do
      code = ~q[
        defmodule UsesStruct do
          def something(%Struct{}) do
          end
        end
      ]

      selector = ~q(
      defmodule Struct do
        defstruc|t [:name, :value]
      end
      )
      assert [location] = references(project, selector, code)
      assert decorate(code, location.range) =~ "def something(«%Struct{}») do"
    end

    test "excludes their definition", %{project: project} do
      code = ~q(
      defmodule Struct do
        defstruct [:field]
      end
      )

      assert [] = references(project, "%Struct|{}", code)
    end
  end

  describe "module attribute references" do
    test "are found in a module", %{project: project} do
      code = ~q[
      defmodule Refs do
        @attr 3

        def fun(@attr), do: true
      end
      ]

      query = ~q[
      defmodule Refs do
        @att|r 3
      end

      ]

      assert [reference] = references(project, query, code)
      assert decorate(code, reference.range) =~ "  def fun(«@attr»), do: true"
    end

    test "includes definitions if the parameter is true", %{project: project} do
      code = ~q[
      defmodule Refs do
        @attr 3

        def fun(@attr), do: true
      end
      ]

      query = ~q[
      defmodule Refs do
        @att|r 3
      end

      ]

      assert [definition, reference] = references(project, query, code, true)
      assert decorate(code, definition.range) =~ "«@attr 3»"
      assert decorate(code, reference.range) =~ "  def fun(«@attr»), do: true"
    end

    test "uses the current analysis without reparsing or querying the index" do
      query = ~q[
      defmodule Refs do
        @attr 3

        def fun(@att|r), do: true
      end
      ]

      {position, document} = pop_cursor(query, as: :document)
      analysis = Ast.analyze(document)

      patch(Ast, :analyze, fn _document -> flunk("references reparsed the document") end)

      assert [reference] = References.references(analysis, position, false)
      assert decorate(document, reference.range) =~ "  def fun(«@attr»), do: true"
      refute_called(Engine.ManagerApi.search_store_exact(_, _, _))
    end

    test "falls back to the index when the full AST is unavailable", %{project: project} do
      code = ~q[
      defmodule Refs do
        @attr 3
        def fun(@attr), do: true
      end
      ]

      query = ~q[
      defmodule Refs do
        @att|r 3
      end
      ]

      {position, referenced} = pop_cursor(query, as: :document)
      {:ok, document} = project_module(project, code)
      {:ok, entries} = Source.index(document.path, code)
      :ok = Engine.ManagerApi.search_store_replace(project, entries)
      analysis = %{Ast.analyze(referenced) | ast: nil, scopes: []}

      assert [reference] = References.references(analysis, position, false)
      assert decorate(code, reference.range) =~ "def fun(«@attr»), do: true"
    end

    test "uses a definition-only dirty analysis without querying the index" do
      query = ~q[
      defmodule Refs do
        @att|r 3
      end
      ]

      {position, document} = pop_cursor(query, as: :document)
      analysis = document |> Document.mark_dirty() |> Ast.analyze()

      assert [definition] = References.references(analysis, position, true)
      assert decorate(document, definition.range) =~ "«@attr 3»"
      refute_called(Engine.ManagerApi.search_store_exact(_, _, _))
    end

    test "does not return stale indexed references after the last local usage is removed", %{
      project: project
    } do
      indexed = ~q[
      defmodule Refs do
        @attr 3
        def fun(@attr), do: true
      end
      ]

      query = ~q[
      defmodule Refs do
        @att|r 3
      end
      ]

      {:ok, entries} = Source.index("refs.ex", indexed)
      :ok = Engine.ManagerApi.search_store_replace(project, entries)
      {position, document} = pop_cursor(query, as: :document)
      analysis = document |> Document.mark_dirty() |> Ast.analyze()

      assert [] = References.references(analysis, position, false)
      refute_called(Engine.ManagerApi.search_store_exact(_, _, _))
    end

    test "does not return stale same-document references after the document is saved", %{
      project: project
    } do
      indexed = ~q[
      defmodule Refs do
        @attr 3
        def fun(@attr), do: true
      end
      ]

      query = ~q[
      defmodule Refs do
        @att|r 3
      end
      ]

      {position, document} = pop_cursor(query, document: file_path(project, "refs.ex"))
      {:ok, entries} = Source.index(document.path, indexed)
      :ok = Engine.ManagerApi.search_store_replace(project, entries)
      analysis = Ast.analyze(document)

      assert [] = References.references(analysis, position, false)
      assert_called(Engine.ManagerApi.search_store_exact(_, _, _))
    end

    test "filters stale same-document results from a cross-document fallback", %{
      project: project
    } do
      indexed = ~q[
      defmodule Refs do
        @attr 3
        def fun(@attr), do: true
      end
      ]

      query = ~q[
      defmodule Refs do
        @att|r 3
      end
      ]

      {position, document} = pop_cursor(query, document: file_path(project, "refs.ex"))
      {:ok, same_document} = Source.index(document.path, indexed)
      {:ok, other_document} = Source.index(file_path(project, "other.ex"), indexed)
      :ok = Engine.ManagerApi.search_store_replace(project, same_document ++ other_document)

      assert [reference] = References.references(Ast.analyze(document), position, false)
      refute reference.uri == document.uri
    end

    test "does not return the same attribute from a nested module" do
      query = ~q[
      defmodule Parent do
        @attr :parent
        def parent, do: @attr

        defmodule Child do
          @attr :child
          def child, do: @att|r
        end
      end
      ]

      {position, document} = pop_cursor(query, as: :document)

      references =
        document
        |> Ast.analyze()
        |> References.references(position, true)

      assert [definition, reference] = references
      assert decorate(document, definition.range) =~ "«@attr :child»"
      assert decorate(document, reference.range) =~ "def child, do: «@attr»"
    end

    test "uses a recoverable AST while the document is invalid" do
      query = ~q[
      defmodule Partial do
        @attr 42
        def first, do: @att|r
        def second, do: @attr
        def incomplete(
      end
      ]

      {position, document} = pop_cursor(query, as: :document)
      analysis = Ast.analyze(document)
      refute analysis.valid?

      assert [first, second] = References.references(analysis, position, false)
      assert decorate(document, first.range) =~ "def first, do: «@attr»"
      assert decorate(document, second.range) =~ "def second, do: «@attr»"

      assert [definition, ^first, ^second] = References.references(analysis, position, true)
      assert decorate(document, definition.range) =~ "«@attr 42»"
      refute_called(Engine.ManagerApi.search_store_exact(_, _, _))
    end
  end

  describe "variable references" do
    test "are found in a function body", %{project: project} do
      query = ~S[
        def my_fun do
          first| = 4
          y = first * 2
          z = y * 3 + first
        end
      ]

      {_, code} = pop_cursor(query)

      assert [ref_1, ref_2] = references(project, query, code)

      assert decorate(code, ref_1.range) =~ "  y = «first» * 2"
      assert decorate(code, ref_2.range) =~ "  z = y * 3 + «first»"
    end

    test "can include definitions", %{project: project} do
      query = ~S[
        def my_fun do
          first = 4
          y = first| * 2
          z = y * 3 + first
        end
      ]

      {_, code} = pop_cursor(query)

      assert [definition, _ref_1, _ref_2] = references(project, query, code, true)
      assert decorate(code, definition.range) =~ "  «first» = 4"
    end
  end

  describe "unsupported entities" do
    test "returns an empty list for plain atoms", %{project: project} do
      query = ~S[
        defmodule MyModule do
          def my_fun do
            :stub_create_consent|
          end
        end
      ]

      {_, code} = pop_cursor(query)

      assert [] == references(project, query, code)
    end
  end

  defp references(project, referenced, code, include_definitions? \\ false) do
    with {position, referenced} <- pop_cursor(referenced, as: :document),
         {:ok, document} <- project_module(project, code),
         {:ok, entries} <- Source.index(document.path, code),
         :ok <- Engine.ManagerApi.search_store_replace(project, entries) do
      referenced
      |> Forge.Ast.analyze()
      |> References.references(position, include_definitions?)
    end
  end
end
