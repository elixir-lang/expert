defmodule Expert.Engine.CodeIntelligence.DefinitionTest do
  alias Engine.Search
  alias Expert.EngineApi
  alias Expert.EngineNode
  alias Expert.EngineSupervisor
  alias Forge.Document

  import Forge.EngineApi.Messages
  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures
  import Forge.Test.RangeSupport

  use ExUnit.Case, async: false

  defp with_referenced_file(%{project: project}) do
    uri =
      project
      |> file_path(Path.join("lib", "my_definition.ex"))
      |> Document.Path.ensure_uri()

    {:ok, _document} = Document.Store.open_temporary(uri)

    on_exit(fn ->
      :ok = Document.Store.close(uri)
    end)

    %{uri: uri}
  end

  defp subject_module_uri(project) do
    project
    |> file_path(Path.join("lib", "my_module.ex"))
    |> Document.Path.ensure_uri()
  end

  defp subject_module(project, content) do
    uri = subject_module_uri(project)

    with :ok <- Document.Store.open(uri, content, 1) do
      Document.Store.fetch(uri)
    end
  end

  setup_all do
    {:ok, _} = start_supervised({Forge.NodePortMapper, []})
    project = project(:navigations)
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    {:ok, _} = start_supervised({EngineSupervisor, project})
    {:ok, _, _} = EngineNode.start(project)

    EngineApi.register_listener(project, self(), [:all])
    EngineApi.schedule_compile(project, true)

    assert_receive project_compiled(), 5000
    assert_receive project_index_ready(), 5000

    %{project: project}
  end

  setup %{project: project} do
    uri = subject_module_uri(project)

    # NOTE: We need to make sure every tests start with fresh caller content file
    on_exit(fn ->
      :ok = Document.Store.close(uri)
    end)

    %{subject_uri: uri}
  end

  describe "definition/2 when making remote call by alias" do
    setup [:with_referenced_file]

    test "find the definition of a remote function call", %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          alias MyDefinition

          def uses_greet() do
            MyDefinition.gree|t("World")
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  def «greet(name)» do]
    end

    test "find the definition of the module", %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          alias MyDefinition

          def uses_greet() do
            MyDefinitio|n.greet("World")
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[defmodule «MyDefinition» do]
    end

    test "find the definition of a struct", %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteStruct do
          alias MyDefinition

          def uses_struct() do
            %|MyDefinition{}
          end
      end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == "  «defstruct [:field, another_field: nil]»"
    end

    test "find the macro definition", %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          require MyDefinition

          def uses_macro() do
            MyDefinition.print_hel|lo()
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  defmacro «print_hello» do]
    end

    test "find the right arity function definition", %{
      project: project,
      uri: referenced_uri
    } do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          alias MultiArity

          def uses_multiple_arity_fun() do
            MultiArity.su|m(1, 2, 3)
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  def «sum»(a, b, c) do]
      assert referenced_uri =~ "navigations/lib/multi_arity.ex"
    end
  end

  describe "definition/2 when making remote call by import" do
    setup [:with_referenced_file]

    test "find the definition of a remote function call", %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          import MyDefinition

          def uses_greet() do
            gree|t("World")
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  def «greet(name)» do]
    end

    test "find the definition of a remote macro call",
         %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          import MyDefinition

          def uses_macro() do
            print_hell|o()
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  defmacro «print_hello» do]
    end
  end

  describe "definition/2 when making remote call by use to import definition" do
    setup [:with_referenced_file]

    test "find the function definition", %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          use MyDefinition

          def uses_greet() do
            gree|t("World")
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  def «greet»(name) do]
    end

    @doc """
    This is a limitation of the ElixirSense.
    like the `subject_module` below, it can't find the correct definition of `hello_func_in_using/0`
    when the definition module aliased by `use` or `import`,
    currently, it will go to the `use MyDefinition` line
    """
    @tag :skip
    test "find the correct definition when func defined in the quote block", %{
      project: project,
      uri: referenced_uri
    } do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          use MyDefinition

          def uses_hello_defined_in_using_quote() do
            hello_func_in_usin|g()
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  def «hello_func_in_using» do]
    end
  end

  describe "definition/2 when making local call" do
    test "find multiple locations when the module is defined in multiple places", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyModule do # line 1
        end

        defmodule MyModule do # line 4
        end

        defmodule UsesMyModule do
          |MyModule
        end
      ]

      {:ok, [{_, definition_line1}, {_, definition_line4}]} =
        definition(project, subject_module, subject_uri)

      assert definition_line1 == ~S[defmodule «MyModule» do # line 1]
      assert definition_line4 == ~S[defmodule «MyModule» do # line 4]
    end

    test "find the function definition", %{project: project, subject_uri: subject_uri} do
      subject_module = ~q[
        defmodule UsesOwnFunction do
          def greet do
          end

          def uses_greet do
            gree|t()
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line == ~S[  def «greet» do]
      assert referenced_uri =~ "navigations/lib/my_module.ex"
    end

    test "find the function definition when the function has `when` clause", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule UsesOwnFunction do
          def greet(name) when is_binary(name) do
          end

          def uses_greet do
            gree|t("World")
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line == ~S[  def «greet(name) when is_binary(name)» do]
      assert referenced_uri =~ "navigations/lib/my_module.ex"
    end

    test "find only one function when there are multiple same arity functions", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule UsesOwnFunction do
          def greet(name) when is_atom(name) do
            IO.inspect(name)
          end

          def greet(name) do
            name
          end

          def uses_greet do
            gree|t("World")
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)
      assert definition_line == ~S[  def «greet(name) when is_atom(name)» do]
      assert referenced_uri == subject_uri
    end

    test "find the attribute", %{project: project, subject_uri: subject_uri} do
      subject_module = ~q[
        defmodule UsesAttribute do
          @b 2

          def use_attribute do
            @|b
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line =~ ~S[«@b» 2]
      assert referenced_uri =~ "navigations/lib/my_module.ex"
    end

    test "find the variable", %{project: project, subject_uri: subject_uri} do
      subject_module = ~q[
        defmodule UsesVariable do
          def use_variable do
            a = 1

            if true do
              |a
            end
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line =~ ~S[«a» = 1]
      assert referenced_uri =~ "navigations/lib/my_module.ex"
    end

    @doc """
    This is a limitation of the ElixirSense.
    like the `subject_module` below, it can't find the correct definition of `String.to_integer/1`,
    currently, it will always return `{:ok, nil}`
    """
    @tag :skip
    test "find the definition when calling a Elixir std module function",
         %{project: project, subject_uri: subject_uri} do
      subject_module = ~q[
        String.to_intege|r("1")
      ]

      {:ok, uri, definition_line} = definition(project, subject_module, subject_uri)

      assert uri =~ "lib/elixir/lib/string.ex"
      assert definition_line =~ ~S[  def «to_integer»(string) when is_binary(string) do]
    end

    test "find the definition when calling a erlang module", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        :erlang.binary_to_ato|m("1")
      ]

      {:ok, uri, definition_line} = definition(project, subject_module, subject_uri)

      assert uri =~ "/src/erlang.erl"
      assert definition_line =~ ~S[«binary_to_atom»(Binary)]
    end
  end

  describe "definition/2 when making local call to a delegated function" do
    setup [:with_referenced_file]

    test "find the definition of the delegated function", %{
      project: project,
      uri: uri,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule UsesDelegatedFunction do
          defdelegate greet(name), to: MyDefinition

          def uses_greet do
            gree|t("World")
          end
        end
      ]

      {:ok, [location1, location2]} = definition(project, subject_module, [uri, subject_uri])

      {referenced_uri, definition_line} = location1
      assert definition_line =~ ~S[  def «greet(name)» do]
      assert referenced_uri == uri

      {referenced_uri, definition_line} = location2
      assert definition_line == ~S[  defdelegate «greet(name)», to: MyDefinition]
      assert referenced_uri == subject_uri
    end
  end

  describe "definition/2 when using HEEX components" do
    setup [:with_referenced_file]

    test "find local function component definition pre", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyLiveView do
          def button(assigns) do
            ~H"""
            <button><%= @label %></button>
            """
          end

          def render(assigns) do
            ~H"""
            <.|button label="Click me" />
            """
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line =~ ~S[def «button(assigns)» do]
      assert referenced_uri == subject_uri
    end

    test "find local function component definition", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyLiveView do
          def button(assigns) do
            ~H"""
            <button><%= @label %></button>
            """
          end

          def render(assigns) do
            ~H"""
            <.butto|n label="Click me" />
            """
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line =~ ~S[def «button(assigns)» do]
      assert referenced_uri == subject_uri
    end

    test "find local function component definition post", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyLiveView do
          def button(assigns) do
            ~H"""
            <button><%= @label %></button>
            """
          end

          def render(assigns) do
            ~H"""
            <.button| label="Click me" />
            """
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line =~ ~S[def «button(assigns)» do]
      assert referenced_uri == subject_uri
    end

    test "find imported function component definition", %{
      project: project,
      uri: referenced_uri
    } do
      subject_module = ~q[
        defmodule MyLiveView do
          import MyDefinition

          def render(assigns) do
            ~H"""
            <.component_gree|t name="World" />
            """
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  def «component_greet(assigns)» do]
    end

    test "find aliased module component definition", %{
      project: project,
      uri: referenced_uri
    } do
      subject_module = ~q[
        defmodule MyLiveView do
          alias MyDefinition

          def render(assigns) do
            ~H"""
            <MyDefinition.component_gree|t name="World" />
            """
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  def «component_greet(assigns)» do]
    end

    test "find component in multiline call", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyLiveView do
          def card(assigns) do
            ~H"""
            <div class="card">
              <%= render_slot(@inner_block) %>
            </div>
            """
          end

          def render(assigns) do
            ~H"""
            <div>
              <.car|d>
                Content here
              </.card>
            </div>
            """
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line =~ ~S[def «card(assigns)» do]
      assert referenced_uri == subject_uri
    end

    test "find component with attributes", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyLiveView do
          def button(assigns) do
            ~H"""
            <button><%= @label %></button>
            """
          end

          def render(assigns) do
            ~H"""
            <.butto|n class="primary" label="Click" phx-click="save" />
            """
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line =~ ~S[def «button(assigns)» do]
      assert referenced_uri == subject_uri
    end

    test "find component in closing tag", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyLiveView do
          def card(assigns) do
            ~H"""
            <div class="card"><%= render_slot(@inner_block) %></div>
            """
          end

          def render(assigns) do
            ~H"""
            <.card>
              Content
            </.car|d>
            """
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line =~ ~S[def «card(assigns)» do]
      assert referenced_uri == subject_uri
    end
  end

  describe "definition/2 with multi-alias syntax" do
    setup [:with_referenced_file]

    test "find definition when cursor on module in simple multi-alias", %{
      project: project,
      uri: referenced_uri
    } do
      subject_module = ~q[
        defmodule UsesMultiAlias do
          alias Foo.{Bar, Ba|z}

          def test do
            :ok
          end
        end
      ]

      # Create a fixture module Foo.Baz for this test
      baz_uri =
        project
        |> file_path(Path.join("lib", "foo_baz.ex"))
        |> Document.Path.ensure_uri()

      baz_content = """
      defmodule Foo.Baz do
        def hello, do: :world
      end
      """

      {:ok, _} = Document.Store.open_temporary(baz_uri, baz_content, 1)

      on_exit(fn ->
        :ok = Document.Store.close(baz_uri)
      end)

      assert {:ok, ^baz_uri, definition_line} =
               definition(project, subject_module, [baz_uri, referenced_uri])

      assert definition_line == ~S[defmodule «Foo.Baz» do]
    end

    test "find definition when cursor on first module in multi-alias", %{
      project: project,
      uri: referenced_uri
    } do
      subject_module = ~q[
        defmodule UsesMultiAlias do
          alias Foo.{B|ar, Baz}

          def test do
            :ok
          end
        end
      ]

      # Create a fixture module Foo.Bar for this test
      bar_uri =
        project
        |> file_path(Path.join("lib", "foo_bar.ex"))
        |> Document.Path.ensure_uri()

      bar_content = """
      defmodule Foo.Bar do
        def hello, do: :world
      end
      """

      {:ok, _} = Document.Store.open_temporary(bar_uri, bar_content, 1)

      on_exit(fn ->
        :ok = Document.Store.close(bar_uri)
      end)

      assert {:ok, ^bar_uri, definition_line} =
               definition(project, subject_module, [bar_uri, referenced_uri])

      assert definition_line == ~S[defmodule «Foo.Bar» do]
    end

    test "find function definition through multi-alias", %{
      project: project,
      uri: referenced_uri
    } do
      bar_uri =
        project
        |> file_path(Path.join("lib", "foo_bar.ex"))
        |> Document.Path.ensure_uri()

      bar_content = """
      defmodule Foo.Bar do
        def hello(name) do
          "Hello, \#{name}!"
        end
      end
      """

      {:ok, _} = Document.Store.open_temporary(bar_uri, bar_content, 1)

      on_exit(fn ->
        :ok = Document.Store.close(bar_uri)
      end)

      subject_module = ~q[
        defmodule UsesMultiAlias do
          alias Foo.{Bar, Baz}

          def test do
            Bar.hell|o("World")
          end
        end
      ]

      assert {:ok, ^bar_uri, definition_line} =
               definition(project, subject_module, [bar_uri, referenced_uri])

      assert definition_line == ~S[  def «hello(name)» do]
    end

    test "find definition with multi-alias containing three modules", %{
      project: project,
      uri: referenced_uri
    } do
      bar_uri =
        project
        |> file_path(Path.join("lib", "foo_bar.ex"))
        |> Document.Path.ensure_uri()

      baz_uri =
        project
        |> file_path(Path.join("lib", "foo_baz.ex"))
        |> Document.Path.ensure_uri()

      qux_uri =
        project
        |> file_path(Path.join("lib", "foo_qux.ex"))
        |> Document.Path.ensure_uri()

      {:ok, _} = Document.Store.open_temporary(bar_uri, "defmodule Foo.Bar, do: :ok", 1)
      {:ok, _} = Document.Store.open_temporary(baz_uri, "defmodule Foo.Baz, do: :ok", 1)
      {:ok, _} = Document.Store.open_temporary(qux_uri, "defmodule Foo.Qux, do: :ok", 1)

      on_exit(fn ->
        :ok = Document.Store.close(bar_uri)
        :ok = Document.Store.close(baz_uri)
        :ok = Document.Store.close(qux_uri)
      end)

      subject_module = ~q[
        defmodule UsesMultiAlias do
          alias Foo.{Bar, Baz, Qu|x}

          def test do
            :ok
          end
        end
      ]

      assert {:ok, ^qux_uri, definition_line} =
               definition(project, subject_module, [bar_uri, baz_uri, qux_uri, referenced_uri])

      assert definition_line == ~S[defmodule «Foo.Qux», do: :ok]
    end

    test "find struct definition through multi-alias", %{
      project: project,
      uri: referenced_uri
    } do
      bar_uri =
        project
        |> file_path(Path.join("lib", "foo_bar.ex"))
        |> Document.Path.ensure_uri()

      bar_content = """
      defmodule Foo.Bar do
        defstruct [:name, :value]
      end
      """

      {:ok, _} = Document.Store.open_temporary(bar_uri, bar_content, 1)

      on_exit(fn ->
        :ok = Document.Store.close(bar_uri)
      end)

      subject_module = ~q[
        defmodule UsesMultiAliasStruct do
          alias Foo.{Bar, Baz}

          def test do
            %B|ar{}
          end
        end
      ]

      assert {:ok, ^bar_uri, definition_line} =
               definition(project, subject_module, [bar_uri, referenced_uri])

      assert definition_line == "  «defstruct [:name, :value]»"
    end

    test "find definition with multi-alias on multiple lines", %{
      project: project,
      uri: referenced_uri
    } do
      bar_uri =
        project
        |> file_path(Path.join("lib", "foo_bar.ex"))
        |> Document.Path.ensure_uri()

      {:ok, _} = Document.Store.open_temporary(bar_uri, "defmodule Foo.Bar, do: :ok", 1)

      on_exit(fn ->
        :ok = Document.Store.close(bar_uri)
      end)

      subject_module = ~q[
        defmodule UsesMultilineMultiAlias do
          alias Foo.{
            B|ar,
            Baz
          }

          def test do
            :ok
          end
        end
      ]

      assert {:ok, ^bar_uri, definition_line} =
               definition(project, subject_module, [bar_uri, referenced_uri])

      assert definition_line == ~S[defmodule «Foo.Bar», do: :ok]
    end

    test "find definition with whitespace in multi-alias", %{
      project: project,
      uri: referenced_uri
    } do
      bar_uri =
        project
        |> file_path(Path.join("lib", "foo_bar.ex"))
        |> Document.Path.ensure_uri()

      {:ok, _} = Document.Store.open_temporary(bar_uri, "defmodule Foo.Bar, do: :ok", 1)

      on_exit(fn ->
        :ok = Document.Store.close(bar_uri)
      end)

      subject_module = ~q[
        defmodule UsesMultiAliasWithSpaces do
          alias Foo.{  Ba|r  ,  Baz  }

          def test do
            :ok
          end
        end
      ]

      assert {:ok, ^bar_uri, definition_line} =
               definition(project, subject_module, [bar_uri, referenced_uri])

      assert definition_line == ~S[defmodule «Foo.Bar», do: :ok]
    end

    test "find definition with nested module in multi-alias", %{
      project: project,
      uri: referenced_uri
    } do
      nested_uri =
        project
        |> file_path(Path.join("lib", "foo_bar_nested.ex"))
        |> Document.Path.ensure_uri()

      {:ok, _} = Document.Store.open_temporary(nested_uri, "defmodule Foo.Bar.Nested, do: :ok", 1)

      on_exit(fn ->
        :ok = Document.Store.close(nested_uri)
      end)

      subject_module = ~q[
        defmodule UsesNestedMultiAlias do
          alias Foo.{Bar.Nest|ed, Baz}

          def test do
            :ok
          end
        end
      ]

      assert {:ok, ^nested_uri, definition_line} =
               definition(project, subject_module, [nested_uri, referenced_uri])

      assert definition_line == ~S[defmodule «Foo.Bar.Nested», do: :ok]
    end

    test "call aliased function from multi-alias with correct arity", %{
      project: project,
      uri: referenced_uri
    } do
      bar_uri =
        project
        |> file_path(Path.join("lib", "foo_bar.ex"))
        |> Document.Path.ensure_uri()

      bar_content = """
      defmodule Foo.Bar do
        def process(x, y, z) do
          x + y + z
        end
      end
      """

      {:ok, _} = Document.Store.open_temporary(bar_uri, bar_content, 1)

      on_exit(fn ->
        :ok = Document.Store.close(bar_uri)
      end)

      subject_module = ~q[
        defmodule UsesMultiAliasArity do
          alias Foo.{Bar, Baz}

          def test do
            Bar.proces|s(1, 2, 3)
          end
        end
      ]

      assert {:ok, ^bar_uri, definition_line} =
               definition(project, subject_module, [bar_uri, referenced_uri])

      assert definition_line == ~S[  def «process(x, y, z)» do]
    end

    test "find macro definition through multi-alias", %{
      project: project,
      uri: referenced_uri
    } do
      bar_uri =
        project
        |> file_path(Path.join("lib", "foo_bar.ex"))
        |> Document.Path.ensure_uri()

      bar_content = """
      defmodule Foo.Bar do
        defmacro debug(expr) do
          quote do: IO.inspect(unquote(expr))
        end
      end
      """

      {:ok, _} = Document.Store.open_temporary(bar_uri, bar_content, 1)

      on_exit(fn ->
        :ok = Document.Store.close(bar_uri)
      end)

      subject_module = ~q[
        defmodule UsesMultiAliasMacro do
          require Foo.{Bar, Baz}

          def test do
            Bar.debu|g(:test)
          end
        end
      ]

      assert {:ok, ^bar_uri, definition_line} =
               definition(project, subject_module, [bar_uri, referenced_uri])

      assert definition_line == ~S[  defmacro «debug(expr)» do]
    end

    test "find definition with imported function from multi-alias", %{
      project: project,
      uri: referenced_uri
    } do
      bar_uri =
        project
        |> file_path(Path.join("lib", "foo_bar.ex"))
        |> Document.Path.ensure_uri()

      bar_content = """
      defmodule Foo.Bar do
        def imported_func(x) do
          x * 2
        end
      end
      """

      {:ok, _} = Document.Store.open_temporary(bar_uri, bar_content, 1)

      on_exit(fn ->
        :ok = Document.Store.close(bar_uri)
      end)

      subject_module = ~q[
        defmodule UsesMultiAliasImport do
          import Foo.{Bar, Baz}

          def test do
            imported_fun|c(5)
          end
        end
      ]

      assert {:ok, ^bar_uri, definition_line} =
               definition(project, subject_module, [bar_uri, referenced_uri])

      assert definition_line == ~S[  def «imported_func(x)» do]
    end

    test "handle multi-alias with single module", %{
      project: project,
      uri: referenced_uri
    } do
      bar_uri =
        project
        |> file_path(Path.join("lib", "foo_bar.ex"))
        |> Document.Path.ensure_uri()

      {:ok, _} = Document.Store.open_temporary(bar_uri, "defmodule Foo.Bar, do: :ok", 1)

      on_exit(fn ->
        :ok = Document.Store.close(bar_uri)
      end)

      subject_module = ~q[
        defmodule UsesSingleMultiAlias do
          alias Foo.{Ba|r}

          def test do
            :ok
          end
        end
      ]

      assert {:ok, ^bar_uri, definition_line} =
               definition(project, subject_module, [bar_uri, referenced_uri])

      assert definition_line == ~S[defmodule «Foo.Bar», do: :ok]
    end

    test "find definition on prefix module before curly brace", %{
      project: project,
      uri: referenced_uri
    } do
      foo_uri =
        project
        |> file_path(Path.join("lib", "foo.ex"))
        |> Document.Path.ensure_uri()

      {:ok, _} = Document.Store.open_temporary(foo_uri, "defmodule Foo, do: :ok", 1)

      on_exit(fn ->
        :ok = Document.Store.close(foo_uri)
      end)

      subject_module = ~q[
        defmodule UsesMultiAliasPrefix do
          alias Fo|o.{Bar, Baz}

          def test do
            :ok
          end
        end
      ]

      assert {:ok, ^foo_uri, definition_line} =
               definition(project, subject_module, [foo_uri, referenced_uri])

      assert definition_line == ~S[defmodule «Foo», do: :ok]
    end
  end

  describe "edge cases" do
    setup [:with_referenced_file]

    test "doesn't crash with structs defined with DSLs", %{project: project, uri: uri} do
      subject_module = ~q[
      defmodule MyTest do
        def my_test(%TypedStructs.MacroBased|Struct{}) do
        end
      end
      ]

      assert {:ok, _file, _definition} = definition(project, subject_module, [uri])
    end
  end

  defp definition(project, code, referenced_uri) do
    with {position, code} <- pop_cursor(code),
         {:ok, document} <- subject_module(project, code),
         :ok <- index(project, referenced_uri),
         {:ok, location} <-
           EngineApi.definition(project, document, position) do
      if is_list(location) do
        {:ok, Enum.map(location, &{&1.document.uri, decorate(&1.document, &1.range)})}
      else
        {:ok, location.document.uri, decorate(location.document, location.range)}
      end
    end
  end

  defp index(project, referenced_uris) when is_list(referenced_uris) do
    entries = Enum.flat_map(referenced_uris, &do_index/1)
    EngineApi.call(project, Search.Store, :replace, [entries])
  end

  defp index(project, referenced_uri) do
    entries = do_index(referenced_uri)
    EngineApi.call(project, Search.Store, :replace, [entries])
  end

  defp do_index(referenced_uri) do
    with {:ok, document} <- Document.Store.fetch(referenced_uri),
         {:ok, entries} <-
           Search.Indexer.Source.index(document.path, Document.to_string(document)) do
      entries
    end
  end
end
