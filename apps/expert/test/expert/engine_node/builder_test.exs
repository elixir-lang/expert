defmodule Expert.EngineNode.BuilderTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Expert.EngineNode.Builder

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

  test "retries with --force when hex dependency resolution fails", %{project: project} do
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

    send(builder_pid, {nil, {:data, {:eol, "** (Mix.Error) Hex dependency resolution failed"}}})

    assert_receive {:attempt, 2, _from}, 1_000

    assert {:ok, {paths, nil}} = Task.await(task, 5_000)
    assert paths == test_ebin_entries()
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

  test "forwards captured output when the build script exits non-zero", %{project: project} do
    test_pid = self()

    patch(Builder, :start_build, fn _project, _from, _opts ->
      send(test_pid, :build_started)
      {:ok, :fake_port}
    end)

    {:ok, builder_pid} = Builder.start_link(project)
    task = Task.async(fn -> GenServer.call(builder_pid, :build, :infinity) end)

    assert_receive :build_started, 1_000

    output = [
      "** (Mix.Error) httpc request failed with: {:failed_connect, ...}.",
      "",
      "Could not install Rebar because Mix could not download metadata at https://builds.hex.pm/installs/rebar.csv.",
      "",
      "    (mix 1.17.3) lib/mix.ex:647: Mix.raise/2",
      "    .../priv/build_engine.exs:31: (file)"
    ]

    Enum.each(output, fn line ->
      send(builder_pid, {nil, {:data, {:eol, line}}})
    end)

    send(builder_pid, {nil, {:exit_status, 1}})

    assert {:error, "Build script exited with status: 1", captured} = Task.await(task, 5_000)
    # The full multi-line output is forwarded so callers see the actual error
    # instead of just the bottom of the stacktrace.
    assert captured =~ "** (Mix.Error) httpc request failed with"
    assert captured =~ "Could not install Rebar because Mix could not download metadata"
    assert captured =~ "build_engine.exs:31: (file)"
  end

  test "forwards captured output when the port crashes", %{project: project} do
    test_pid = self()
    fake_port = make_ref()

    patch(Builder, :start_build, fn _project, _from, _opts ->
      send(test_pid, :build_started)
      {:ok, fake_port}
    end)

    {:ok, builder_pid} = Builder.start_link(project)
    task = Task.async(fn -> GenServer.call(builder_pid, :build, :infinity) end)

    assert_receive :build_started, 1_000

    # Set the port that the GenServer is monitoring so the {:EXIT, port, reason}
    # clause matches.
    :sys.replace_state(builder_pid, fn state -> %{state | port: fake_port} end)

    send(builder_pid, {nil, {:data, {:eol, "** (RuntimeError) something went wrong"}}})
    send(builder_pid, {nil, {:data, {:eol, "    .../build_engine.exs:33: (file)"}}})
    send(builder_pid, {:EXIT, fake_port, :killed})

    assert {:error, :killed, captured} = Task.await(task, 5_000)
    assert captured =~ "** (RuntimeError) something went wrong"
    assert captured =~ "build_engine.exs:33: (file)"
  end

  test "caps captured output at the configured maximum", %{project: project} do
    test_pid = self()

    patch(Builder, :start_build, fn _project, _from, _opts ->
      send(test_pid, :build_started)
      {:ok, :fake_port}
    end)

    {:ok, builder_pid} = Builder.start_link(project)
    task = Task.async(fn -> GenServer.call(builder_pid, :build, :infinity) end)

    assert_receive :build_started, 1_000

    # Send 200 lines (well above the @max_output_lines cap of 50).
    for n <- 1..200 do
      send(builder_pid, {nil, {:data, {:eol, "line #{n}"}}})
    end

    send(builder_pid, {nil, {:exit_status, 1}})

    assert {:error, _msg, captured} = Task.await(task, 5_000)
    captured_lines = String.split(captured, "\n")
    # 50 retained body lines preceded by a single marker line indicating omission.
    assert length(captured_lines) == 51
    assert List.first(captured_lines) == "...(150 earlier line(s) omitted)"
    assert Enum.at(captured_lines, 1) == "line 151"
    assert List.last(captured_lines) == "line 200"
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
