defmodule Engine.ProgressTest do
  use ExUnit.Case
  use Patch

  alias Engine.Dispatch
  alias Engine.Progress

  setup do
    test_pid = self()

    # Mock rpc_call for begin - returns {:ok, token}
    patch(Dispatch, :rpc_call, fn Expert.Progress, :begin, [title, opts] ->
      token = System.unique_integer([:positive])
      send(test_pid, {:begin, token, title, opts})
      {:ok, token}
    end)

    # Mock rpc_cast for report and complete
    patch(Dispatch, :rpc_cast, fn Expert.Progress, function, args ->
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
end
