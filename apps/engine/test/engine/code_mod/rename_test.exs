defmodule Engine.CodeMod.RenameTest do
  alias Engine.CodeMod.Rename
  alias Engine.Search
  alias Engine.Search.Store.Backends
  alias Forge.Document

  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures
  import Forge.Test.EventualAssertions

  setup do
    project = project()

    Backends.Ets.destroy_all(project)
    Engine.set_project(project)

    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    start_supervised!(Engine.Dispatch)
    start_supervised!(Backends.Ets)

    start_supervised!(
      {Search.Store, [project, fn _ -> {:ok, []} end, fn _, _ -> {:ok, [], []} end, Backends.Ets]}
    )

    Search.Store.enable()
    assert_eventually(Search.Store.loaded?(), 1500)

    on_exit(fn ->
      Backends.Ets.destroy_all(project)
    end)

    {:ok, project: project}
  end

  describe "prepare/2 function" do
    test "returns function name at defp definition" do
      {:ok, result, _} =
        ~q[
        defmodule MyApp.Users do
          defp |helper do
            :ok
          end
        end
      ]
        |> prepare()

      assert result == "helper"
    end

    test "returns function name at defp definition with args" do
      {:ok, result, _} =
        ~q[
        defmodule MyApp.Users do
          defp |helper(x), do: x
        end
      ]
        |> prepare()

      assert result == "helper"
    end

    test "returns function name at function call" do
      {:ok, result, _} =
        ~q[
        defmodule MyApp.Users do
          def run, do: |helper()

          defp helper, do: :ok
        end
      ]
        |> prepare()

      assert result == "helper"
    end

    test "returns nil for variables" do
      assert {:ok, nil} =
               ~q[
        defmodule MyApp.Users do
          def run do
            |x = 1
          end
        end
      ]
               |> prepare()
    end
  end

  describe "rename/4 function" do
    test "renames private function at definition" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Users do
          def run, do: helper()

          defp |helper do
            :ok
          end
        end
      ]
        |> rename("do_work")

      assert result =~ "do_work()"
      assert result =~ "defp do_work do"
      refute result =~ "helper"
    end

    test "renames private function at zero-arg definition" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Users do
          def run, do: helper()

          defp |helper do
            helper()
            :ok
          end
        end
      ]
        |> rename("do_work")

      assert result =~ "do_work()"
      assert result =~ "defp do_work do"
      refute result =~ "helper"
    end

    test "renames private function at call site" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Users do
          def run, do: |helper()

          defp helper do
            :ok
          end
        end
      ]
        |> rename("do_work")

      assert result =~ "do_work()"
      assert result =~ "defp do_work do"
      refute result =~ "helper"
    end

    test "renames function with multiple clauses" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Users do
          def run, do: |process(:a)

          defp process(:a), do: 1
          defp process(:b), do: 2
        end
      ]
        |> rename("handle")

      assert result =~ "handle(:a)"
      assert result =~ "defp handle(:a)"
      assert result =~ "defp handle(:b)"
      refute result =~ "process"
    end

    test "renames function with matching arity only" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Users do
          def run, do: |helper(1, 2)

          defp helper(a, b), do: a + b
          defp helper(a, b, c), do: a + b + c
        end
      ]
        |> rename("compute")

      assert result =~ "compute(1, 2)"
      assert result =~ "defp compute(a, b)"
      assert result =~ "defp helper(a, b, c)"
    end

    test "does not affect functions in other modules" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Users do
          def run, do: |helper()

          defp helper, do: :ok
        end

        defmodule MyApp.Other do
          defp helper, do: :other
        end
      ]
        |> rename("do_work")

      assert result =~ "defp do_work"
      assert result =~ "defmodule MyApp.Other do\n  defp helper"
    end

    test "renames piped function calls" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Users do
          def run(data), do: data |> |transform()

          defp transform(data), do: data
        end
      ]
        |> rename("process")

      assert result =~ "|> process()"
      assert result =~ "defp process(data)"
      refute result =~ "transform"
    end

    test "returns empty changes for unsupported rename" do
      assert {:ok, result} =
               ~q[
        defmodule MyApp.Users do
          def |run, do: :ok
        end
      ]
               |> rename("execute")

      assert is_binary(result)
    end
  end

  # Helpers

  defp prepare(code) do
    with {position, code} <- pop_cursor(code),
         {:ok, _document, analysis} <- index(code) do
      Rename.prepare(analysis, position)
    end
  end

  defp rename(code, new_name) do
    with {position, code} <- pop_cursor(code),
         {:ok, document, analysis} <- index(code),
         {:ok, results} <- Rename.rename(analysis, position, new_name, nil) do
      case results do
        [%Document.Changes{edits: edits, document: doc}] ->
          {:ok, edited_doc} =
            Document.apply_content_changes(doc, doc.version + 1, edits)

          {:ok, Document.to_string(edited_doc)}

        [] ->
          {:ok, Document.to_string(document)}
      end
    end
  end

  defp index(code) do
    project = project()
    uri = module_uri(project)

    with :ok <- Document.Store.open(uri, code, 1),
         {:ok, document, analysis} <- Document.Store.fetch(uri, :analysis),
         {:ok, entries} <- Engine.Search.Indexer.Quoted.index(analysis) do
      Search.Store.replace(entries)
      {:ok, document, analysis}
    end
  end

  defp module_uri(project) do
    project
    |> file_path(Path.join("lib", "my_module.ex"))
    |> Document.Path.ensure_uri()
  end
end
