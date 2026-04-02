defmodule Engine.Build.StateTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Engine.Build
  alias Engine.Build.State
  alias Engine.Plugin
  alias Forge.Document
  alias Forge.Project

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

  def with_bare_project_state(_) do
    test = self()

    patch(Engine.Dispatch, :broadcast, &send(test, &1))

    fixture_dir = fixtures_path()
    project = Project.bare("file://#{fixture_dir}")
    state = State.new(project)

    Engine.set_project(project)
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
  describe "bare project compilation" do
    setup [:with_bare_project_state, :with_a_valid_document]

    test "document compilation does not enter Mix project context", %{
      state: state,
      document: document
    } do
      patch(Engine.Mix, :in_project, fn _fun -> {:error, :should_not_be_called} end)

      State.compile_file(state, document)

      refute_called(Engine.Mix.in_project(_))
    end

    test "project compilation returns :ok without calling Mix", %{state: state} do
      patch(Engine.Mix, :in_project, fn _project, _fun -> {:error, :should_not_be_called} end)

      assert Engine.Build.Project.compile(state.project, true) == :ok

      refute_called(Engine.Mix.in_project(_, _))
    end
  end

  describe "fetching deps" do
    test "returns :ok when deps fetch succeeds" do
      {:ok, state} = with_project_state(:project_metadata)

      patch(File, :rm_rf, fn _path -> {:ok, []} end)
      patch(Build.Project, :fetch_deps, fn _project -> :ok end)

      assert {^state, :ok} = State.fetch_deps(state, state.project)
    end

    test "returns error when deps fetch fails" do
      {:ok, state} = with_project_state(:project_metadata)

      patch(File, :rm_rf, fn _path -> {:ok, []} end)
      patch(Build.Project, :fetch_deps, fn _project -> {:error, "deps failed"} end)

      assert {^state, {:error, "deps failed"}} = State.fetch_deps(state, state.project)
    end
  end
end
