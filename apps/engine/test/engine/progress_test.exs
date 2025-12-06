defmodule Engine.ProgressTest do
  use ExUnit.Case
  use Patch

  alias Engine.Progress

  setup do
    test_pid = self()
    patch(Engine.Api.Proxy, :broadcast, &send(test_pid, &1))
    :ok
  end

  test "it should send begin/complete event and return the result" do
    result = Progress.with_progress("foo", fn _token -> {:done, :ok} end)

    assert result == :ok
    assert_received {:engine_progress_begin, token, "foo", []} when is_integer(token)
    assert_received {:engine_progress_complete, ^token, []}
  end

  test "it should send begin/complete event with final message" do
    result = Progress.with_progress("bar", fn _token -> {:done, :success, "Completed!"} end)

    assert result == :success
    assert_received {:engine_progress_begin, token, "bar", []} when is_integer(token)
    assert_received {:engine_progress_complete, ^token, [message: "Completed!"]}
  end

  test "it should send report events when Progress.report is called" do
    result =
      Progress.with_progress("indexing", fn token ->
        Progress.report(token, message: "Processing file 1...")
        Progress.report(token, message: "Processing file 2...", percentage: 50)
        {:done, :indexed}
      end)

    assert result == :indexed
    assert_received {:engine_progress_begin, token, "indexing", []} when is_integer(token)
    assert_received {:engine_progress_report, ^token, [message: "Processing file 1..."]}

    assert_received {:engine_progress_report, ^token,
                     [message: "Processing file 2...", percentage: 50]}

    assert_received {:engine_progress_complete, ^token, []}
  end

  test "it should send begin/complete event even when there is an exception" do
    assert_raise(Mix.Error, fn ->
      Progress.with_progress("compile", fn _token -> raise Mix.Error, "can't compile" end)
    end)

    assert_received {:engine_progress_begin, token, "compile", []} when is_integer(token)
    assert_received {:engine_progress_complete, ^token, [message: "Error: can't compile"]}
  end

  test "it should handle cancel result" do
    result = Progress.with_progress("cancellable", fn _token -> {:cancel, :cancelled} end)

    assert result == :cancelled
    assert_received {:engine_progress_begin, token, "cancellable", []} when is_integer(token)
    assert_received {:engine_progress_complete, ^token, [message: "Cancelled"]}
  end

  test "it should pass through initial options" do
    _result =
      Progress.with_progress(
        "with_opts",
        fn _token -> {:done, :ok} end,
        message: "Starting...",
        percentage: 0
      )

    assert_received {:engine_progress_begin, _token, "with_opts", opts}
    assert opts[:message] == "Starting..."
    assert opts[:percentage] == 0
  end
end
