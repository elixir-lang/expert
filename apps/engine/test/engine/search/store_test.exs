defmodule Engine.Search.StoreTest do
  alias Engine.Dispatch
  alias Engine.Search.Indexer
  alias Engine.Search.Store
  alias Engine.Search.Store.Backends.Ets
  alias Engine.Search.Store.Backends.Sqlite
  alias Forge.Search.Indexer.Entry
  alias Forge.Test.EventualAssertions
  alias Forge.Test.Fixtures

  use ExUnit.Case, async: false

  import Engine.Test.Entry.Builder
  import EventualAssertions
  import Fixtures
  import Forge.Test.CodeSigil

  @backends [Sqlite]

  setup_all do
    project = project()
    Engine.set_project(project)
    # These test cases require an clean slate going into them
    # so we should remove the indexes once when the tests start,
    # and again when tests end, so the next test has a clean slate.
    # Removing the index at the end will also let other test cases
    # start with a clean slate.

    destroy_backends(project)

    on_exit(fn ->
      destroy_backends(project)
    end)

    {:ok, project: project}
  end

  def all_entries(backend) do
    []
    |> backend.reduce(fn entry, acc -> [entry | acc] end)
    |> Enum.reverse()
  end

  for backend <- @backends,
      backend_name = backend |> Module.split() |> List.last() do
    describe "#{backend_name} :: replace/1" do
      setup %{project: project} do
        with_a_started_store(project, unquote(backend))
      end

      test "replaces the entire index" do
        entries = [definition(subject: OtherModule)]

        Store.replace(entries)
        assert entries == all_entries(unquote(backend))
      end
    end

    describe "#{backend_name} :: querying" do
      setup %{project: project} do
        with_a_started_store(project, unquote(backend))
      end

      test "matching can exclude on type" do
        Store.replace([
          definition(id: 1),
          reference(id: 3)
        ])

        assert {:ok, [ref]} = Store.exact(subtype: :reference)
        assert ref.subtype == :reference
      end

      test "matching with queries can exclude on type" do
        Store.replace([
          reference(subject: Foo.Bar.Baz),
          reference(subject: Other.Module),
          definition(subject: Foo.Bar.Baz)
        ])

        assert {:ok, [ref]} = Store.exact("Foo.Bar.Baz", subtype: :reference)

        assert ref.subject == Foo.Bar.Baz
        assert ref.type == :module
        assert ref.subtype == :reference
      end

      test "matching exact tokens should work" do
        Store.replace([
          definition(id: 1, subject: Foo.Bar.Baz),
          definition(id: 2, subject: Foo.Bar.Bak)
        ])

        assert {:ok, [entry]} = Store.exact("Foo.Bar.Baz", type: :module, subtype: :definition)

        assert entry.subject == Foo.Bar.Baz
        assert entry.id == 1
      end

      test "matching prefix tokens should work" do
        Store.replace([
          definition(id: 1, subject: Foo.Bar),
          definition(id: 2, subject: Foo.Baa.Baa),
          definition(id: 3, subject: Foo.Bar.Baz)
        ])

        assert {:ok, [entry1, entry3]} =
                 Store.prefix("Foo.Bar", type: :module, subtype: :definition)

        assert entry1.subject == Foo.Bar
        assert entry3.subject == Foo.Bar.Baz

        assert entry1.id == 1
        assert entry3.id == 3
      end

      test "matching fuzzy tokens works" do
        Store.replace([
          definition(id: 1, subject: Foo.Bar.Baz),
          definition(id: 2, subject: Foo.Bar.Bak),
          definition(id: 3, subject: Bad.Times.Now)
        ])

        assert {:ok, [entry_1, entry_2]} =
                 Store.fuzzy("Foo.Bar.B", type: :module, subtype: :definition)

        assert entry_1.subject in [Foo.Bar.Baz, Foo.Bar.Bak]
        assert entry_2.subject in [Foo.Bar.Baz, Foo.Bar.Bak]
      end
    end

    describe "#{backend_name} :: updating entries in a file" do
      setup %{project: project} do
        with_a_started_store(project, unquote(backend))
      end

      test "old entries with the same path are deleted" do
        path = "/path/to/file.ex"

        Store.replace([
          definition(id: 1, subject: Foo.Bar.Baz, path: path),
          definition(id: 2, subject: Foo.Baz.Quux, path: path)
        ])

        updated = [
          definition(id: 3, subject: Other.Thing.Entirely, path: path)
        ]

        Store.update(path, updated)

        assert_eventually [remaining] = all_entries(unquote(backend))
        refute remaining.id in [1, 2]
      end

      test "old entries with another path are kept" do
        updated_path = "/path/to/file.ex"

        Store.replace([
          definition(id: 1, subject: Foo.Bar.Baz, path: updated_path),
          definition(id: 2, subject: Foo.Bar.Baz.Quus, path: updated_path),
          definition(id: 3, subject: Foo.Bar.Baz, path: "/path/to/another.ex")
        ])

        updated = [
          definition(id: 4, subject: Other.Thing.Entirely, path: updated_path)
        ]

        Store.update(updated_path, updated)

        assert_eventually [first, second] = all_entries(unquote(backend))

        assert first.id in [3, 4]
        assert second.id in [3, 4]
      end

      test "updated entries are not searchable" do
        path = "/path/to/ex.ex"

        Store.replace([
          definition(id: 1, subject: Should.Be.Replaced, path: path)
        ])

        Store.update(path, [
          definition(id: 2, subject: Present, path: path)
        ])

        assert_eventually {:ok, [found]} =
                            Store.fuzzy("Pres", type: :module, subtype: :definition)

        assert found.id == 2
        assert found.subject == Present
      end
    end

    describe "#{backend_name} :: structure queries " do
      setup %{project: project} do
        with_a_started_store(project, unquote(backend))
      end

      test "finding siblings" do
        entries =
          ~q[
            defmodule Parent do
              def function do
                First.Module
                Second.Module
                Third.Module
              end
            end
          ]
          |> entries()

        subject_entry = Enum.find(entries, &(&1.subject == Third.Module))
        assert {:ok, [first_ref, second_ref, ^subject_entry]} = Store.siblings(subject_entry)
        assert first_ref.subject == First.Module
        assert second_ref.subject == Second.Module
      end

      test "finding siblings of a function" do
        entries =
          ~q[
          defmodule Parent do
            def fun do
             :ok
            end

            def fun2(arg) do
              arg + 1
            end

            def fun3(arg, arg2) do
              arg + arg2
            end
          end
          ]
          |> entries()

        subject_entry = Enum.find(entries, &(&1.subject == "Parent.fun3/2"))

        assert {:ok, siblings} = Store.siblings(subject_entry)
        siblings = Enum.filter(siblings, &(&1.subtype == :definition))

        assert [first_fun, second_fun, ^subject_entry] = siblings
        assert first_fun.subject == "Parent.fun/0"
        assert second_fun.subject == "Parent.fun2/1"
      end

      test "findidng siblings of a non-existent entry" do
        assert :error = Store.siblings(%Entry{})
      end

      test "finding a parent in a function" do
        entries =
          ~q[
            defmodule Parent do
              def function do
                Module.Ref
              end
            end
          ]
          |> entries()

        subject_entry = Enum.find(entries, &(&1.subject == Module.Ref))
        {:ok, parent} = Store.parent(subject_entry)

        assert parent.subject == "Parent.function/0"
        assert parent.type == {:function, :public}
        assert parent.subtype == :definition

        assert {:ok, parent} = Store.parent(parent)
        assert parent.subject == Parent

        assert :error = Store.parent(parent)
      end

      test "finding a parent in a comprehension" do
        entries =
          ~q[
          defmodule Parent do
            def fun do
              for n <- 1..10 do
                Module.Ref
              end
            end
          end
          ]
          |> entries()

        subject_entry = Enum.find(entries, &(&1.subject == Module.Ref))
        assert {:ok, parent} = Store.parent(subject_entry)
        assert parent.subject == "Parent.fun/0"
      end

      test "finding parents in a file with multiple nested modules" do
        entries =
          ~q[
          defmodule Parent do
            defmodule Child do
              def fun do
              end
            end
          end

          defmodule Parent2 do
            defmodule Child2 do
              def fun2 do
                Module.Ref
              end
            end
          end
          ]
          |> entries()

        subject_entry = Enum.find(entries, &(&1.subject == Module.Ref))

        assert {:ok, parent} = Store.parent(subject_entry)

        assert parent.subject == "Parent2.Child2.fun2/0"
        assert {:ok, parent} = Store.parent(parent)
        assert parent.subject == Parent2.Child2

        assert {:ok, parent} = Store.parent(parent)
        assert parent.subject == Parent2
      end

      test "finding a non-existent entry" do
        assert Store.parent(%Entry{}) == :error
      end
    end
  end

  defp entries(source) do
    document = Forge.Document.new("file:///file.ex", source, 1)

    {:ok, entries} =
      document
      |> Forge.Ast.analyze()
      |> Indexer.Quoted.index_with_cleanup()

    Store.replace(entries)
    entries
  end

  defp after_each_test(backend, project) do
    destroy_backend(backend, project)
  end

  defp destroy_backends(project) do
    Enum.each(@backends, &destroy_backend(&1, project))
  end

  defp destroy_backend(Ets, project) do
    Ets.destroy_all(project)
  end

  defp destroy_backend(_, _) do
    :ok
  end

  defp default_create(_project) do
    {:ok, []}
  end

  defp default_update(_project, _entities) do
    {:ok, [], []}
  end

  defp with_a_started_store(project, backend) do
    destroy_backend(backend, project)

    start_supervised!(Dispatch)
    start_supervised!(backend)
    start_supervised!({Store, [project, &default_create/1, &default_update/2, backend]})

    assert_eventually alive?()

    Store.enable()

    assert_eventually ready?(), 1500

    on_exit(fn ->
      after_each_test(backend, project)
    end)

    {:ok, backend: backend}
  end

  def ready? do
    alive?() and Store.loaded?()
  end

  def alive? do
    case Process.whereis(Store) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end
end
