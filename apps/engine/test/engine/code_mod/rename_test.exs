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
    assert_eventually Search.Store.loaded?(), 1500

    on_exit(fn ->
      Backends.Ets.destroy_all(project)
    end)

    {:ok, project: project}
  end

  describe "prepare/2" do
    test "returns the module name" do
      {:ok, result, _} =
        ~q[
        defmodule |Foo do
        end
      ]
        |> prepare()

      assert result == "Foo"
    end

    test "returns the whole module name" do
      {:ok, result, _} =
        ~q[
        defmodule TopLevel.|Foo do
        end
      ]
        |> prepare()

      assert result == "TopLevel.Foo"
    end

    test "returns the whole module name even if the cursor is not at the end" do
      {:ok, result, _} =
        ~q[
        defmodule Top|Level.Foo do
        end
      ]
        |> prepare()

      assert result == "TopLevel.Foo"
    end

    test "returns `nil` when renaming a module occurs in a reference" do
      assert {:ok, nil} =
               ~q[
        defmodule Foo do
        end

        defmodule Bar do
          alias |Foo
        end
      ]
               |> prepare()
    end

    test "returns error when the entity is not found" do
      assert {:error, "Renaming :variable is not supported for now"} =
               ~q[
          x = 1
          |x
      ]
               |> prepare()
    end
  end

  describe "rename exact module" do
    test "succeeds when the cursor is at the definition" do
      {:ok, result} =
        ~q[
        defmodule |Foo do
        end
      ]
        |> rename("Renamed")

      assert result =~ ~S[defmodule Renamed do]
    end

    test "failed when the cursor is at the alias" do
      assert {:error, {:unsupported_location, :module}} ==
               ~q[
        defmodule Baz do
          alias |Foo
        end
      ]
               |> rename("Renamed")
    end

    test "succeeds when the module has multiple dots" do
      {:ok, result} =
        ~q[
        defmodule TopLevel.Foo.|Bar do
        end
      ]
        |> rename("TopLevel.Foo.Renamed")

      assert result =~ ~S[defmodule TopLevel.Foo.Renamed do]
    end

    test "succeeds when renaming the middle part of the module" do
      {:ok, result} =
        ~q[
        defmodule TopLevel.Foo.|Bar do
        end
      ]
        |> rename("TopLevel.Renamed.Bar")

      assert result =~ ~S[defmodule TopLevel.Renamed.Bar do]
    end

    test "succeeds when simplifying the module name" do
      {:ok, result} =
        ~q[
        defmodule TopLevel.Foo.|Bar do
        end
      ]
        |> rename("TopLevel.Bar")

      assert result =~ ~S[defmodule TopLevel.Bar do]
    end
  end

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
