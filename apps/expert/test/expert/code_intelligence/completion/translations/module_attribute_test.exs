defmodule Expert.CodeIntelligence.Completion.Translations.ModuleAttributeTest do
  alias GenLSP.Enumerations.CompletionItemKind

  use Expert.Test.Expert.CompletionCase

  describe "module attributes" do
    test "@moduledoc completions", %{project: project} do
      source = ~q[
        defmodule Docs do
          @modu|
        end
      ]

      assert [snippet_completion, empty_completion] = complete(project, source)

      assert snippet_completion.detail
      assert snippet_completion.label == "@moduledoc"

      # note: indentation should be correctly adjusted by editor
      assert apply_completion(snippet_completion) == ~q[
        defmodule Docs do
          @moduledoc """
        $0
        """
        end
      ]

      assert empty_completion.detail
      assert empty_completion.label == "@moduledoc false"

      assert apply_completion(empty_completion) == ~q[
        defmodule Docs do
          @moduledoc false
        end
      ]
    end

    test "@doc completions", %{project: project} do
      source = ~q[
        defmodule MyModule do
          @d|
          def other_thing do
          end
        end
      ]

      assert {:ok, [snippet_completion, empty_completion]} =
               project
               |> complete(source)
               |> fetch_completion(kind: CompletionItemKind.property())

      assert snippet_completion.detail
      assert snippet_completion.label == "@doc"
      assert snippet_completion.kind == CompletionItemKind.property()

      # note: indentation should be correctly adjusted by editor
      assert apply_completion(snippet_completion) == ~q[
        defmodule MyModule do
          @doc """
        $0
        """
          def other_thing do
          end
        end
      ]

      assert empty_completion.detail
      assert empty_completion.label == "@doc false"
      assert empty_completion.kind == CompletionItemKind.property()

      assert apply_completion(empty_completion) == ~q[
        defmodule MyModule do
          @doc false
          def other_thing do
          end
        end
      ]
    end

    # This is a limitation of ElixirSense, which does not return @doc as
    # a suggestion when the prefix is `@do`. It does for both `@d` and `@doc`.
    @tag :skip
    test "@doc completion with do prefix", %{project: project} do
      source = ~q[
        defmodule MyModule do
          @do|
          def other_thing do
          end
        end
      ]

      assert {:ok, [_snippet_completion, empty_completion]} =
               project
               |> complete(source)
               |> fetch_completion(kind: CompletionItemKind.property())

      assert empty_completion.detail
      assert empty_completion.label == "@doc"
      assert empty_completion.kind == CompletionItemKind.property()

      assert apply_completion(empty_completion) == ~q[
        defmodule MyModule do
          @doc false
          def other_thing do
          end
        end
      ]
    end

    test "local attribute completion with prefix", %{project: project} do
      source = ~q[
        defmodule Attr do
          @my_attribute :foo
          @my_|
        end
      ]

      assert [completion] = complete(project, source)
      assert completion.label == "@my_attribute"

      assert apply_completion(completion) == ~q[
        defmodule Attr do
          @my_attribute :foo
          @my_attribute
        end
      ]
    end

    test "local attribute completion immediately after @", %{project: project} do
      source = ~q[
        defmodule Attr do
          @my_attribute :foo
          @|
        end
      ]

      assert {:ok, completion} =
               project
               |> complete(source)
               |> fetch_completion("@my_attribute")

      assert completion.label == "@my_attribute"

      assert apply_completion(completion) == ~q[
        defmodule Attr do
          @my_attribute :foo
          @my_attribute
        end
      ]
    end
  end

  describe "@spec completion" do
    test "with no function following", %{project: project} do
      source = ~q[
        defmodule MyModule do
          @spe|
        end
      ]

      assert {:ok, completion} =
               project
               |> complete(source)
               |> fetch_completion("@spec")

      assert apply_completion(completion) == ~q[
        defmodule MyModule do
          @spec ${1:function}(${2:term()}) :: ${3:term()}
        def ${1:function}(${4:args}) do
          $0
        end
      end
      ]
    end

    test "with a function with args after it", %{project: project} do
      source = ~q[
        defmodule MyModule do
          @spe|
          def my_function(arg1, arg2, arg3) do
            :ok
          end
        end
      ]

      assert {:ok, [spec_my_function, spec]} =
               project
               |> complete(source)
               |> fetch_completion(kind: CompletionItemKind.property())

      assert spec_my_function.label == "@spec my_function"

      assert apply_completion(spec_my_function) == ~q[
        defmodule MyModule do
          @spec my_function(${1:term()}, ${2:term()}, ${3:term()}) :: ${0:term()}
          def my_function(arg1, arg2, arg3) do
            :ok
          end
        end
      ]

      assert spec.label == "@spec"

      assert apply_completion(spec) == ~q[
        defmodule MyModule do
          @spec ${1:function}(${2:term()}) :: ${3:term()}
        def ${1:function}(${4:args}) do
          $0
        end
          def my_function(arg1, arg2, arg3) do
            :ok
          end
        end
      ]
    end

    test "with a function without args after it", %{project: project} do
      source = ~q[
        defmodule MyModule do
          @spe|
          def my_function do
            :ok
          end
        end
      ]

      assert {:ok, [spec_my_function, spec]} =
               project
               |> complete(source)
               |> fetch_completion(kind: CompletionItemKind.property())

      assert spec_my_function.label == "@spec my_function"

      assert apply_completion(spec_my_function) == ~q[
        defmodule MyModule do
          @spec my_function() :: ${0:term()}
          def my_function do
            :ok
          end
        end
      ]

      assert spec.label == "@spec"

      assert apply_completion(spec) == ~q[
        defmodule MyModule do
          @spec ${1:function}(${2:term()}) :: ${3:term()}
        def ${1:function}(${4:args}) do
          $0
        end
          def my_function do
            :ok
          end
        end
      ]
    end

    test "with a function with guards after it", %{project: project} do
      source = ~q[
        defmodule MyModule do
          @spe|
          def my_function(arg1, arg2, arg3) when is_binary(arg1) do
            :ok
          end
        end
      ]

      assert {:ok, [spec_my_function, spec]} =
               project
               |> complete(source)
               |> fetch_completion(kind: CompletionItemKind.property())

      assert spec_my_function.label == "@spec my_function"

      assert apply_completion(spec_my_function) == ~q[
        defmodule MyModule do
          @spec my_function(${1:term()}, ${2:term()}, ${3:term()}) :: ${0:term()}
          def my_function(arg1, arg2, arg3) when is_binary(arg1) do
            :ok
          end
        end
      ]

      assert spec.label == "@spec"

      assert apply_completion(spec) == ~q[
        defmodule MyModule do
          @spec ${1:function}(${2:term()}) :: ${3:term()}
        def ${1:function}(${4:args}) do
          $0
        end
          def my_function(arg1, arg2, arg3) when is_binary(arg1) do
            :ok
          end
        end
      ]
    end

    test "with a private function after it", %{project: project} do
      source = ~q[
        defmodule MyModule do
          @spe|
          defp my_function(arg1, arg2, arg3) do
            :ok
          end
        end
      ]

      assert {:ok, [spec_my_function, _spec]} =
               project
               |> complete(source)
               |> fetch_completion(kind: CompletionItemKind.property())

      assert spec_my_function.label == "@spec my_function"

      assert apply_completion(spec_my_function) == ~q[
        defmodule MyModule do
          @spec my_function(${1:term()}, ${2:term()}, ${3:term()}) :: ${0:term()}
          defp my_function(arg1, arg2, arg3) do
            :ok
          end
        end
      ]
    end
  end
end
