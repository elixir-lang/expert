defmodule Expert.EngineBuildsTest do
  alias Expert.EngineBuilds
  alias Expert.EngineNode.Builder
  alias Forge.Project

  import Forge.Test.Fixtures

  use ExUnit.Case, async: false
  use Patch

  setup do
    start_supervised!({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})
    start_supervised!(EngineBuilds)
    :ok
  end

  test "builds once for concurrent callers with the same toolchain" do
    project_a = project(:project)
    project_b = project(:umbrella)
    calls = :counters.new(1, [])
    result = {test_ebin_entries(), "/tmp/mix_home"}

    patch(Expert.Port, :project_executable, fn _project, name ->
      case name do
        "elixir" -> {:ok, ~c"/toolchains/elixir/bin/elixir", []}
        "erl" -> {:ok, ~c"/toolchains/otp/bin/erl", []}
      end
    end)

    patch(System, :cmd, fn _command, ["--eval", _script], _opts ->
      {runtime_key_output("1.17.3", "15.2.7.4"), 0}
    end)

    patch(Builder, :start_build, fn _project, build, _opts ->
      assert build == [elixir: ~c"/toolchains/elixir/bin/elixir", env: []]
      :counters.add(calls, 1, 1)
      Process.sleep(100)
      send(self(), {:build_result, {:ok, result}})
      {:ok, :fake_port}
    end)

    task_a = Task.async(fn -> EngineBuilds.request_engine(project_a) end)
    task_b = Task.async(fn -> EngineBuilds.request_engine(project_b) end)

    assert {:ok, ^result} = Task.await(task_a, 1_000)
    assert {:ok, ^result} = Task.await(task_b, 1_000)
    assert :counters.get(calls, 1) == 1
  end

  test "reuses the cached build for later callers" do
    project = project()
    calls = :counters.new(1, [])
    result = {test_ebin_entries(), "/tmp/mix_home"}

    patch(Expert.Port, :project_executable, fn _project, name ->
      case name do
        "elixir" -> {:ok, ~c"/toolchains/elixir/bin/elixir", []}
        "erl" -> {:ok, ~c"/toolchains/otp/bin/erl", []}
      end
    end)

    patch(System, :cmd, fn _command, ["--eval", _script], _opts ->
      {runtime_key_output("1.17.3", "15.2.7.4"), 0}
    end)

    patch(Builder, :start_build, fn _project, _build, _opts ->
      :counters.add(calls, 1, 1)
      send(self(), {:build_result, {:ok, result}})
      {:ok, :fake_port}
    end)

    assert {:ok, ^result} = EngineBuilds.request_engine(project)
    assert {:ok, ^result} = EngineBuilds.request_engine(project)
    assert :counters.get(calls, 1) == 1
  end

  test "builds separately for different toolchains" do
    project_a = project(:project)
    project_b = project(:umbrella)
    test_pid = self()
    result = {test_ebin_entries(), "/tmp/mix_home"}

    patch(Expert.Port, :project_executable, fn project, name ->
      suffix =
        project
        |> Project.root_path()
        |> Path.basename()

      case name do
        "elixir" -> {:ok, to_charlist("/toolchains/#{suffix}/bin/elixir"), []}
        "erl" -> {:ok, to_charlist("/toolchains/#{suffix}/bin/erl"), []}
      end
    end)

    patch(System, :cmd, fn _command, ["--eval", _script], opts ->
      version =
        case opts[:cd] |> Path.basename() do
          "project" -> {"1.17.3", "15.2.7.4"}
          "umbrella" -> {"1.18.0", "16.0.0"}
        end

      {runtime_key_output(elem(version, 0), elem(version, 1)), 0}
    end)

    patch(Builder, :start_build, fn _project, build, _opts ->
      tag =
        build
        |> Keyword.fetch!(:elixir)
        |> List.to_string()
        |> Path.dirname()
        |> Path.dirname()
        |> Path.basename()

      send(test_pid, {:builder_started, tag, self()})

      receive do
        {:release_builder, ^tag} ->
          send(self(), {:build_result, {:ok, result}})
          {:ok, :fake_port}
      end
    end)

    task_a = Task.async(fn -> EngineBuilds.request_engine(project_a) end)
    task_b = Task.async(fn -> EngineBuilds.request_engine(project_b) end)

    assert_receive first_started, 1_000
    assert_receive second_started, 1_000

    builders =
      Map.new([first_started, second_started], fn {:builder_started, tag, pid} -> {tag, pid} end)

    assert builders |> Map.keys() |> Enum.sort() == ["project", "umbrella"]

    send(builders["project"], {:release_builder, "project"})
    send(builders["umbrella"], {:release_builder, "umbrella"})

    assert {:ok, ^result} = Task.await(task_a, 1_000)
    assert {:ok, ^result} = Task.await(task_b, 1_000)
  end

  test "does not cache failed builds" do
    project = project()
    calls = :counters.new(1, [])

    patch(Expert.Port, :project_executable, fn _project, name ->
      case name do
        "elixir" -> {:ok, ~c"/toolchains/elixir/bin/elixir", []}
        "erl" -> {:ok, ~c"/toolchains/otp/bin/erl", []}
      end
    end)

    patch(System, :cmd, fn _command, ["--eval", _script], _opts ->
      {runtime_key_output("1.17.3", "15.2.7.4"), 0}
    end)

    patch(Builder, :start_build, fn _project, _build, _opts ->
      :counters.add(calls, 1, 1)
      send(self(), {:build_result, {:error, :build_failed}})
      {:ok, :fake_port}
    end)

    assert {:error, :build_failed} = EngineBuilds.request_engine(project)
    assert {:error, :build_failed} = EngineBuilds.request_engine(project)
    assert :counters.get(calls, 1) == 2
  end

  test "does not reuse a build when two projects share the same shim path" do
    project_a = project(:project)
    project_b = project(:umbrella)
    calls = :counters.new(1, [])
    result = {test_ebin_entries(), "/tmp/mix_home"}

    patch(Expert.Port, :project_executable, fn _project, name ->
      case name do
        "elixir" -> {:ok, ~c"/toolchains/shims/elixir", []}
        "erl" -> {:ok, ~c"/toolchains/shims/erl", []}
      end
    end)

    patch(System, :cmd, fn _command, ["--eval", _script], opts ->
      version =
        case opts[:cd] |> Path.basename() do
          "project" -> {"1.17.3", "15.2.7.4"}
          "umbrella" -> {"1.18.0", "16.0.0"}
        end

      {runtime_key_output(elem(version, 0), elem(version, 1)), 0}
    end)

    patch(Builder, :start_build, fn _project, _build, _opts ->
      :counters.add(calls, 1, 1)
      send(self(), {:build_result, {:ok, result}})
      {:ok, :fake_port}
    end)

    assert {:ok, ^result} = EngineBuilds.request_engine(project_a)
    assert {:ok, ^result} = EngineBuilds.request_engine(project_b)
    assert :counters.get(calls, 1) == 2
  end

  defp test_ebin_entries do
    ["/tmp/dev_ns/lib/engine/ebin"]
  end

  defp runtime_key_output(elixir_version, erts_version) do
    {elixir_version, erts_version}
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end
end
