defmodule Engine.Build.StateTest do
  alias Engine.Build
  alias Engine.Build.State
  alias Engine.Plugin
  alias Forge.Document
  alias Forge.Project

  import Forge.Test.Fixtures

  use ExUnit.Case, async: false
  use Patch

  setup do
    start_supervised!(Engine.Dispatch)
    start_supervised!(Engine.Api.Proxy)
    start_supervised!(Build.CaptureServer)
    start_supervised!(Engine.ModuleMappings)
    start_supervised!(Plugin.Runner.Coordinator)
    start_supervised!(Plugin.Runner.Supervisor)
    :ok
  end

  def document(%State{} = state, filename \\ "file.ex", source_code) do
    sequence = System.unique_integer([:monotonic, :positive])

    uri =
      state.project
      |> Project.root_path()
      |> Path.join(to_string(sequence))
      |> Path.join(filename)
      |> Document.Path.to_uri()

    Document.new(uri, source_code, 0)
  end

  def with_project_state(project_name) do
    test = self()

    patch(Engine.Dispatch, :broadcast, &send(test, &1))

    project_name = to_string(project_name)
    fixture_dir = Path.join(fixtures_path(), project_name)
    project = Project.new("file://#{fixture_dir}")
    state = State.new(project)

    Engine.set_project(project)
    {:ok, state}
  end

  def with_metadata_project(_) do
    {:ok, state} = with_project_state(:project_metadata)
    {:ok, state: state}
  end

  def with_a_valid_document(%{state: state}) do
    source = ~S[
      defmodule Testing.ValidSource do
        def add(a, b) do
          a + b
        end
      end
    ]

    document = document(state, source)
    {:ok, document: document}
  end

  def with_patched_compilation(_) do
    patch(Build.Document, :compile, :ok)
    patch(Build.Project, :compile, :ok)
    # Patch Progress and building_label to avoid side effects during state tests
    patch(State, :building_label, "Building test")
    patch(Engine.Progress, :begin, fn _, _ -> 0 end)
    patch(Engine.Progress, :complete, fn _, _ -> :ok end)
    :ok
  end

  describe "throttled document compilation" do
    setup [:with_metadata_project, :with_a_valid_document, :with_patched_compilation]

    test "it doesn't compile immediately", %{state: state, document: document} do
      State.on_file_compile(state, document)

      refute_called(Build.Document.compile(document))
      refute_called(Build.Project.compile(_, _))
    end

    test "it compiles files when on_timeout is called", %{state: state, document: document} do
      state
      |> State.on_file_compile(document)
      |> State.on_timeout()

      assert_called(Build.Document.compile(document))
      refute_called(Build.Project.compile(_, _))
    end
  end

  describe "throttled project compilation" do
    setup [:with_metadata_project, :with_a_valid_document, :with_patched_compilation]

    test "doesn't compile immediately if forced", %{state: state} do
      State.on_project_compile(state, true)
      refute_called(Build.Project.compile(_, _))
    end

    test "doesn't compile immediately", %{state: state} do
      State.on_project_compile(state, false)
      refute_called(Build.Project.compile(_, _))
    end

    test "compiles if force is true after on_timeout is called", %{state: state} do
      state
      |> State.on_project_compile(true)
      |> State.on_timeout()

      assert_called(Build.Project.compile(_, true))
    end

    test "compiles after on_timeout is called", %{state: state} do
      state
      |> State.on_project_compile(false)
      |> State.on_timeout()

      assert_called(Build.Project.compile(_, false))
    end
  end

  describe "mixed compilation" do
    setup [:with_metadata_project, :with_a_valid_document, :with_patched_compilation]

    test "doesn't compile if both documents and projects are added", %{
      state: state,
      document: document
    } do
      state
      |> State.on_project_compile(false)
      |> State.on_file_compile(document)

      refute_called(Build.Document.compile(_))
      refute_called(Build.Project.compile(_, _))
    end

    test "compiles when on_timeout is called if both documents and projects are added", %{
      state: state,
      document: document
    } do
      state
      |> State.on_project_compile(false)
      |> State.on_file_compile(document)
      |> State.on_timeout()

      assert_called(Build.Document.compile(_))
      assert_called(Build.Project.compile(_, _))
    end
  end
end
