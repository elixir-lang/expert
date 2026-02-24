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
    send(builder_pid, {nil, {:data, "Unchecked dependencies for environment dev:"}})

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
    send(builder_pid, {nil, {:data, error_line}})

    assert_receive :build_started, 1_000
    send(builder_pid, {nil, {:data, error_line}})

    assert {:error, "Build failed due to dependency errors after 1 attempts", ^error_line} =
             Task.await(task, 5_000)
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
