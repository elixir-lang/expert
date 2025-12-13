defmodule Expert.ProgressTest do
  use ExUnit.Case
  use Patch

  alias Expert.Progress
  alias GenLSP.Notifications
  alias GenLSP.Requests
  alias GenLSP.Structures

  setup do
    test_pid = self()
    lsp = spawn(fn -> Process.sleep(:infinity) end)

    patch(Expert, :get_lsp, fn -> lsp end)
    patch(Expert.Configuration, :client_support, fn :work_done_progress -> true end)

    # Mock GenLSP.request to return nil (success) and send the request to test process
    patch(GenLSP, :request, fn ^lsp, request ->
      send(test_pid, {:request, request})
      nil
    end)

    # Mock GenLSP.notify to send the notification to test process
    patch(GenLSP, :notify, fn ^lsp, notification ->
      send(test_pid, {:notify, notification})
      :ok
    end)

    on_exit(fn -> Process.exit(lsp, :kill) end)

    :ok
  end

  describe "begin/2" do
    test "generates a token and sends begin notification" do
      assert {:ok, token} = Progress.begin("Building")

      assert is_integer(token)

      # Should request the client to create the progress
      assert_received {:request, %Requests.WindowWorkDoneProgressCreate{params: params}}
      assert params.token == token

      # Should send begin notification
      assert_received {:notify, %Notifications.DollarProgress{params: params}}
      assert params.token == token
      assert %Structures.WorkDoneProgressBegin{} = params.value
      assert params.value.title == "Building"
      assert params.value.kind == "begin"
    end

    test "passes options to begin notification" do
      {:ok, _token} = Progress.begin("Building", message: "Starting...", percentage: 0)

      assert_received {:notify, %Notifications.DollarProgress{params: params}}
      assert params.value.message == "Starting..."
      assert params.value.percentage == 0
    end

    test "returns error when client rejects the token" do
      patch(GenLSP, :request, fn _lsp, _request -> {:error, :rejected} end)

      assert {:error, :rejected} = Progress.begin("Building")
    end
  end

  describe "report/2" do
    test "sends report notification" do
      {:ok, token} = Progress.begin("Building")
      # Clear the received messages
      assert_received {:request, _}
      assert_received {:notify, _}

      :ok = Progress.report(token, message: "Processing...")

      assert_received {:notify, %Notifications.DollarProgress{params: params}}
      assert params.token == token
      assert %Structures.WorkDoneProgressReport{} = params.value
      assert params.value.message == "Processing..."
      assert params.value.kind == "report"
    end

    test "supports percentage option" do
      {:ok, token} = Progress.begin("Building")
      assert_received {:request, _}
      assert_received {:notify, _}

      :ok = Progress.report(token, message: "Halfway", percentage: 50)

      assert_received {:notify, %Notifications.DollarProgress{params: params}}
      assert params.value.percentage == 50
    end
  end

  describe "complete/2" do
    test "sends end notification" do
      {:ok, token} = Progress.begin("Building")
      assert_received {:request, _}
      assert_received {:notify, _}

      :ok = Progress.complete(token, message: "Done!")

      assert_received {:notify, %Notifications.DollarProgress{params: params}}
      assert params.token == token
      assert %Structures.WorkDoneProgressEnd{} = params.value
      assert params.value.message == "Done!"
      assert params.value.kind == "end"
    end
  end

  describe "with_progress/3" do
    test "wraps work with begin/complete" do
      result = Progress.with_progress("Building", fn _token -> {:done, :ok} end)

      assert result == :ok

      # Should have begin notification
      assert_received {:request, _}
      assert_received {:notify, %Notifications.DollarProgress{params: begin_params}}
      assert begin_params.value.kind == "begin"

      # Should have end notification
      assert_received {:notify, %Notifications.DollarProgress{params: end_params}}
      assert end_params.value.kind == "end"
    end

    test "passes final message on completion" do
      Progress.with_progress("Building", fn _token -> {:done, :ok, "Build complete"} end)

      assert_received {:request, _}
      assert_received {:notify, _}
      assert_received {:notify, %Notifications.DollarProgress{params: params}}
      assert params.value.message == "Build complete"
    end

    test "handles cancel result" do
      result = Progress.with_progress("Building", fn _token -> {:cancel, :cancelled} end)

      assert result == :cancelled

      assert_received {:request, _}
      assert_received {:notify, _}
      assert_received {:notify, %Notifications.DollarProgress{params: params}}
      assert params.value.message == "Cancelled"
    end

    test "handles exceptions" do
      assert_raise RuntimeError, "oops", fn ->
        Progress.with_progress("Building", fn _token -> raise "oops" end)
      end

      assert_received {:request, _}
      assert_received {:notify, _}
      assert_received {:notify, %Notifications.DollarProgress{params: params}}
      assert params.value.message == "Error: oops"
    end

    test "allows reporting during work" do
      Progress.with_progress("Building", fn token ->
        Progress.report(token, message: "Step 1")
        Progress.report(token, message: "Step 2")
        {:done, :ok}
      end)

      assert_received {:request, _}
      assert_received {:notify, %Notifications.DollarProgress{params: begin_params}}
      assert begin_params.value.kind == "begin"

      assert_received {:notify, %Notifications.DollarProgress{params: report1}}
      assert report1.value.message == "Step 1"

      assert_received {:notify, %Notifications.DollarProgress{params: report2}}
      assert report2.value.message == "Step 2"

      assert_received {:notify, %Notifications.DollarProgress{params: end_params}}
      assert end_params.value.kind == "end"
    end
  end

  describe "when client does not support progress" do
    setup do
      patch(Expert.Configuration, :client_support, fn :work_done_progress -> false end)
      :ok
    end

    test "begin still returns a token" do
      assert {:ok, token} = Progress.begin("Building")
      assert is_integer(token)

      # Should NOT send any requests or notifications
      refute_received {:request, _}
      refute_received {:notify, _}
    end

    test "with_progress still executes the work" do
      result = Progress.with_progress("Building", fn _token -> {:done, :ok} end)

      assert result == :ok
      refute_received {:notify, _}
    end
  end
end
