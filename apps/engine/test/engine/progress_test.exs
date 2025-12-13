defmodule Engine.ProgressTest do
  use ExUnit.Case
  use Patch

  alias Engine.Dispatch
  alias Engine.Progress

  setup do
    test_pid = self()

    # Mock erpc_call for begin - returns {:ok, token}
    patch(Dispatch, :erpc_call, fn Expert.Progress, :begin, [title, opts] ->
      token = System.unique_integer([:positive])
      send(test_pid, {:begin, token, title, opts})
      {:ok, token}
    end)

    # Mock erpc_cast for report and complete
    patch(Dispatch, :erpc_cast, fn Expert.Progress, function, args ->
      send(test_pid, {function, args})
      true
    end)

    :ok
  end

  test "it should send begin/complete event and return the result" do
    result = Progress.with_progress("foo", fn _token -> {:done, :ok} end)

    assert result == :ok
    assert_received {:begin, token, "foo", []} when is_integer(token)
    assert_received {:complete, [^token, []]}
  end

  test "it should send begin/complete event with final message" do
    result = Progress.with_progress("bar", fn _token -> {:done, :success, "Completed!"} end)

    assert result == :success
    assert_received {:begin, token, "bar", []} when is_integer(token)
    assert_received {:complete, [^token, [message: "Completed!"]]}
  end

  test "it should send report events when Progress.report is called" do
    result =
      Progress.with_progress("indexing", fn token ->
        Progress.report(token, message: "Processing file 1...")
        Progress.report(token, message: "Processing file 2...", percentage: 50)
        {:done, :indexed}
      end)

    assert result == :indexed
    assert_received {:begin, token, "indexing", []} when is_integer(token)
    assert_received {:report, [^token, [message: "Processing file 1..."]]}
    assert_received {:report, [^token, [message: "Processing file 2...", percentage: 50]]}
    assert_received {:complete, [^token, []]}
  end

  test "it should send begin/complete event even when there is an exception" do
    assert_raise(Mix.Error, fn ->
      Progress.with_progress("compile", fn _token -> raise Mix.Error, "can't compile" end)
    end)

    assert_received {:begin, token, "compile", []} when is_integer(token)
    assert_received {:complete, [^token, [message: "Error: can't compile"]]}
  end

  test "it should handle cancel result" do
    result = Progress.with_progress("cancellable", fn _token -> {:cancel, :cancelled} end)

    assert result == :cancelled
    assert_received {:begin, token, "cancellable", []} when is_integer(token)
    assert_received {:complete, [^token, [message: "Cancelled"]]}
  end

  test "it should pass through initial options" do
    _result =
      Progress.with_progress(
        "with_opts",
        fn _token -> {:done, :ok} end,
        message: "Starting...",
        percentage: 0
      )

    assert_received {:begin, _token, "with_opts", opts}
    assert opts[:message] == "Starting..."
    assert opts[:percentage] == 0
  end

  describe "with_tracked_progress/3" do
    test "tracks progress via GenServer and reports percentage" do
      result =
        Progress.with_tracked_progress("Indexing", 100, fn report ->
          report.(message: "Processing", add: 25)
          report.(message: "Processing", add: 25)
          report.(message: "Processing", add: 50)
          {:done, :indexed}
        end)

      assert result == :indexed
      assert_received {:begin, token, "Indexing", [percentage: 0]} when is_integer(token)
      assert_received {:report, [^token, [message: "Processing", percentage: 25]]}
      assert_received {:report, [^token, [message: "Processing", percentage: 50]]}
      assert_received {:report, [^token, [message: "Processing", percentage: 100]]}
      assert_received {:complete, [^token, []]}
    end

    test "handles concurrent updates from multiple tasks" do
      result =
        Progress.with_tracked_progress("Concurrent", 100, fn report ->
          1..10
          |> Task.async_stream(fn i ->
            report.(message: "Task #{i}", add: 10)
            i
          end)
          |> Enum.map(fn {:ok, i} -> i end)
          |> then(&{:done, &1})
        end)

      assert result == Enum.to_list(1..10)
      assert_received {:begin, token, "Concurrent", [percentage: 0]} when is_integer(token)
      # Should receive 10 report messages (order may vary due to concurrency)
      for _ <- 1..10 do
        assert_received {:report, [^token, [message: _, percentage: _]]}
      end

      assert_received {:complete, [^token, []]}
    end

    test "completes with final message" do
      result =
        Progress.with_tracked_progress("WithMessage", 10, fn report ->
          report.(message: "Working", add: 10)
          {:done, :success, "All done!"}
        end)

      assert result == :success
      assert_received {:begin, token, "WithMessage", [percentage: 0]} when is_integer(token)
      assert_received {:complete, [^token, [message: "All done!"]]}
    end

    test "handles cancel result" do
      result =
        Progress.with_tracked_progress("Cancellable", 100, fn _report ->
          {:cancel, :stopped}
        end)

      assert result == :stopped
      assert_received {:begin, token, "Cancellable", [percentage: 0]} when is_integer(token)
      assert_received {:complete, [^token, [message: "Cancelled"]]}
    end

    test "cleans up tracker on exception" do
      assert_raise RuntimeError, "oops", fn ->
        Progress.with_tracked_progress("Failing", 100, fn _report ->
          raise "oops"
        end)
      end

      assert_received {:begin, token, "Failing", [percentage: 0]} when is_integer(token)
      assert_received {:complete, [^token, [message: "Error: oops"]]}
    end

    test "caps percentage at 100 when add exceeds total" do
      result =
        Progress.with_tracked_progress("Overflow", 50, fn report ->
          report.(message: "Big chunk", add: 100)
          {:done, :ok}
        end)

      assert result == :ok
      assert_received {:begin, token, "Overflow", [percentage: 0]} when is_integer(token)
      assert_received {:report, [^token, [message: "Big chunk", percentage: 100]]}
    end
  end

  describe "with_tracked_progress/4 with custom report function" do
    test "uses custom report callback" do
      test_pid = self()

      custom_report = fn message, current, total, token ->
        send(test_pid, {:custom_report, message, current, total, token})
      end

      result =
        Progress.with_tracked_progress(
          "Custom",
          10,
          fn report ->
            report.(message: "Step 1", add: 3)
            report.(message: "Step 2", add: 7)
            {:done, :customized}
          end,
          custom_report
        )

      assert result == :customized
      assert_received {:begin, token, "Custom", [percentage: 0]} when is_integer(token)
      assert_received {:custom_report, "Step 1", 3, 10, ^token}
      assert_received {:custom_report, "Step 2", 10, 10, ^token}
      assert_received {:complete, [^token, []]}
    end

    test "custom report receives nil message when not provided" do
      test_pid = self()

      custom_report = fn message, current, total, token ->
        send(test_pid, {:custom_report, message, current, total, token})
      end

      Progress.with_tracked_progress(
        "NoMessage",
        10,
        fn report ->
          report.(add: 5)
          {:done, :ok}
        end,
        custom_report
      )

      assert_received {:begin, token, "NoMessage", [percentage: 0]} when is_integer(token)
      assert_received {:custom_report, nil, 5, 10, ^token}
    end
  end
end
