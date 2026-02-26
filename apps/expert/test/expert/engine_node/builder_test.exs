defmodule Expert.EngineNode.BuilderTest do
  alias Expert.EngineNode.Builder

  import Forge.Test.Fixtures

  use ExUnit.Case, async: false
  use Patch

  setup do
    {:ok, project: project()}
  end

  test "retries with --force when a dep error is detected", %{project: project} do
    test_pid = self()
    attempt_counter = :counters.new(1, [])

    patch(Builder, :start_build, fn _project, from, opts ->
      :counters.add(attempt_counter, 1, 1)
      current_attempt = :counters.get(attempt_counter, 1)

      case current_attempt do
        1 ->
          refute opts[:force]
          send(test_pid, {:attempt, 1, from})

        2 ->
          assert opts[:force]
          GenServer.reply(from, {:ok, {test_ebin_entries(), nil}})
          send(test_pid, {:attempt, 2, from})
      end

      {:ok, :fake_port}
    end)

    {:ok, builder_pid} = Builder.start_link(project)
    task = Task.async(fn -> GenServer.call(builder_pid, :build, :infinity) end)

    assert_receive {:attempt, 1, _from}, 1_000
    send(builder_pid, {nil, {:data, {:eol, "Unchecked dependencies for environment dev:"}}})

    assert_receive {:attempt, 2, _from}, 1_000

    assert {:ok, {paths, nil}} = Task.await(task, 5_000)
    assert paths == test_ebin_entries()
  end

  test "returns error after exhausting max retry attempts", %{project: project} do
    test_pid = self()

    patch(Builder, :start_build, fn _project, _from, _opts ->
      send(test_pid, :build_started)
      {:ok, :fake_port}
    end)

    {:ok, builder_pid} = Builder.start_link(project)
    task = Task.async(fn -> GenServer.call(builder_pid, :build, :infinity) end)

    error_line = "Unchecked dependencies for environment dev:"

    assert_receive :build_started, 1_000
    send(builder_pid, {nil, {:data, {:eol, error_line}}})

    assert_receive :build_started, 1_000
    send(builder_pid, {nil, {:data, {:eol, error_line}}})

    assert {:error, "Build failed due to dependency errors after 1 attempts", ^error_line} =
             Task.await(task, 5_000)
  end

  test "parses engine_meta after unrelated output", %{project: project} do
    patch(Builder, :start_build, fn _project, _from, _opts ->
      {:ok, :fake_port}
    end)

    {:ok, builder_pid} = Builder.start_link(project)
    task = Task.async(fn -> GenServer.call(builder_pid, :build, :infinity) end)

    engine_path = Path.join(System.tmp_dir!(), "dev_ns")
    mix_home = Path.join(System.tmp_dir!(), "mix_home")

    meta =
      %{mix_home: mix_home, engine_path: engine_path}
      |> :erlang.term_to_binary()
      |> Base.encode64()

    send(builder_pid, {nil, {:data, {:eol, "Rewriting 0 config scripts."}}})
    send(builder_pid, {nil, {:data, {:eol, "engine_meta:#{meta}"}}})

    assert {:ok, {paths, ^mix_home}} = Task.await(task, 5_000)
    assert paths == Forge.Path.glob([engine_path, "lib/**/ebin"])
  end

  test "parses engine_meta across chunks", %{project: project} do
    patch(Builder, :start_build, fn _project, _from, _opts ->
      {:ok, :fake_port}
    end)

    {:ok, builder_pid} = Builder.start_link(project)
    task = Task.async(fn -> GenServer.call(builder_pid, :build, :infinity) end)

    engine_path = Path.join(System.tmp_dir!(), "dev_ns")
    mix_home = Path.join(System.tmp_dir!(), "mix_home")

    meta =
      %{mix_home: mix_home, engine_path: engine_path}
      |> :erlang.term_to_binary()
      |> Base.encode64()

    {first, second} = String.split_at("engine_meta:#{meta}", 8)

    send(builder_pid, {nil, {:data, {:noeol, first}}})
    send(builder_pid, {nil, {:data, {:eol, second}}})

    assert {:ok, {paths, ^mix_home}} = Task.await(task, 5_000)
    assert paths == Forge.Path.glob([engine_path, "lib/**/ebin"])
  end

  @excluded_apps [:patch, :nimble_parsec]
  @allowed_apps [:engine | Mix.Project.deps_apps()] -- @excluded_apps

  defp test_ebin_entries do
    [Mix.Project.build_path(), "**/ebin"]
    |> Forge.Path.glob()
    |> Enum.filter(fn entry ->
      Enum.any?(@allowed_apps, &String.contains?(entry, to_string(&1)))
    end)
  end
end
