defmodule Expert.Project.ProgressTest do
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Expert.Project
  alias Expert.Test.DispatchFake
  alias GenLSP.Notifications
  alias GenLSP.Requests
  alias GenLSP.Structures

  import Forge.Test.Fixtures

  use ExUnit.Case
  use Patch
  use DispatchFake
  use Forge.Test.EventualAssertions

  @progress_message_types [
    :engine_progress_begin,
    :engine_progress_report,
    :engine_progress_complete
  ]

  setup do
    project = project()
    pid = start_supervised!({Project.Progress, project})
    DispatchFake.start()

    for type <- @progress_message_types do
      Engine.Dispatch.register_listener(pid, type)
    end

    {:ok, project: project}
  end

  def with_patched_transport(_) do
    test = self()

    patch(Expert, :get_lsp, fn -> self() end)

    patch(GenLSP, :notify, fn _, message ->
      send(test, {:transport, message})
      :ok
    end)

    # GenLSP.request returns nil for success
    patch(GenLSP, :request, fn _, message ->
      send(test, {:transport, message})
      nil
    end)

    :ok
  end

  def with_work_done_progress_support(_) do
    patch(Configuration, :client_supports?, fn :work_done_progress -> true end)
    :ok
  end

  describe "engine-initiated progress" do
    setup [:with_patched_transport, :with_work_done_progress_support]

    test "it should send begin/report/complete notifications", %{project: project} do
      # Engine generates token and broadcasts begin
      engine_token = 12345

      EngineApi.broadcast(project, {:engine_progress_begin, engine_token, "mix compile", []})

      assert_receive {:transport,
                      %Requests.WindowWorkDoneProgressCreate{
                        params: %Structures.WorkDoneProgressCreateParams{token: ^engine_token}
                      }}

      assert_receive {:transport, %Notifications.DollarProgress{params: %{value: value}}}
      assert value.kind == "begin"
      assert value.title == "mix compile"

      # Report progress
      EngineApi.broadcast(
        project,
        {:engine_progress_report, engine_token, [message: "lib/file.ex"]}
      )

      assert_receive {:transport,
                      %Notifications.DollarProgress{
                        params: %Structures.ProgressParams{token: ^engine_token, value: value}
                      }}

      assert value.kind == "report"
      assert value.message == "lib/file.ex"

      # Complete progress
      EngineApi.broadcast(
        project,
        {:engine_progress_complete, engine_token, [message: "Done"]}
      )

      assert_receive {:transport,
                      %Notifications.DollarProgress{
                        params: %Structures.ProgressParams{token: ^engine_token, value: value}
                      }}

      assert value.kind == "end"
      assert value.message == "Done"
    end

    test "it should support percentage updates", %{project: project} do
      engine_token = 67890

      EngineApi.broadcast(
        project,
        {:engine_progress_begin, engine_token, "indexing", [percentage: 0]}
      )

      assert_receive {:transport,
                      %Requests.WindowWorkDoneProgressCreate{params: %{token: ^engine_token}}}

      assert_receive {:transport, %Notifications.DollarProgress{params: %{value: value}}}

      assert value.kind == "begin"
      assert value.title == "indexing"
      assert value.percentage == 0

      EngineApi.broadcast(
        project,
        {:engine_progress_report, engine_token, [message: "Processing...", percentage: 50]}
      )

      assert_receive {:transport,
                      %Notifications.DollarProgress{
                        params: %Structures.ProgressParams{token: ^engine_token, value: value}
                      }}

      assert value.kind == "report"
      assert value.percentage == 50
      assert value.message == "Processing..."

      EngineApi.broadcast(
        project,
        {:engine_progress_complete, engine_token, [message: "Complete"]}
      )

      assert_receive {:transport,
                      %Notifications.DollarProgress{params: %{token: ^engine_token, value: value}}}

      assert value.kind == "end"
      assert value.message == "Complete"
    end

    test "it should write nothing when the client does not support work done", %{project: project} do
      patch(Configuration, :client_supports?, fn :work_done_progress -> false end)

      EngineApi.broadcast(project, {:engine_progress_begin, 11111, "mix compile", []})

      refute_receive {:transport, %Requests.WindowWorkDoneProgressCreate{params: %{}}}
    end

    test "it ignores updates for unknown tokens", %{project: project} do
      # Report/complete without a matching begin should not crash
      EngineApi.broadcast(project, {:engine_progress_report, 99999, [message: "test"]})
      EngineApi.broadcast(project, {:engine_progress_complete, 99999, []})

      # Should not receive any notifications for unknown progress
      refute_receive {:transport, %Notifications.DollarProgress{}}
    end
  end

  describe "manual progress API" do
    setup [:with_patched_transport, :with_work_done_progress_support]

    test "register/3 registers a client-initiated progress with ref", %{project: project} do
      client_token = "client-token-123"

      :ok = Project.Progress.register(project, client_token, ref: :initialize)

      # Report using the ref (cast, returns :ok immediately)
      :ok = Project.Progress.report(project, :initialize, message: "Loading...")

      assert_receive {:transport,
                      %Notifications.DollarProgress{
                        params: %{token: ^client_token, value: value}
                      }}

      assert value.kind == "report"
      assert value.message == "Loading..."

      # End using the ref
      :ok = Project.Progress.complete(project, :initialize, message: "Done")

      assert_receive {:transport,
                      %Notifications.DollarProgress{
                        params: %{token: ^client_token, value: value}
                      }}

      assert value.kind == "end"
      assert value.message == "Done"
    end

    test "begin/3 starts server-initiated progress and returns token", %{project: project} do
      {:ok, token} = Project.Progress.begin(project, "Building", message: "Starting...")

      assert is_integer(token)

      assert_receive {:transport,
                      %Requests.WindowWorkDoneProgressCreate{params: %{token: ^token}}}

      assert_receive {:transport,
                      %Notifications.DollarProgress{params: %{token: ^token, value: value}}}

      assert value.kind == "begin"
      assert value.title == "Building"
      assert value.message == "Starting..."
    end

    test "report/3 with token sends progress update", %{project: project} do
      {:ok, token} = Project.Progress.begin(project, "Processing")

      # Drain begin notifications
      assert_receive {:transport, %Requests.WindowWorkDoneProgressCreate{}}

      assert_receive {:transport,
                      %Notifications.DollarProgress{params: %{value: %{kind: "begin"}}}}

      # report is now a cast, returns :ok immediately
      :ok = Project.Progress.report(project, token, message: "50% complete", percentage: 50)

      assert_receive {:transport,
                      %Notifications.DollarProgress{params: %{token: ^token, value: value}}}

      assert value.kind == "report"
      assert value.message == "50% complete"
      assert value.percentage == 50
    end

    test "report/3 with unknown ref is a no-op", %{project: project} do
      # report is a cast, always returns :ok (unknown refs are silently ignored with warning log)
      result = Project.Progress.report(project, :nonexistent_ref, message: "test")
      assert result == :ok
    end

    test "complete/3 with token completes progress", %{project: project} do
      {:ok, token} = Project.Progress.begin(project, "Task")

      # Drain begin notifications
      assert_receive {:transport, %Requests.WindowWorkDoneProgressCreate{}}

      assert_receive {:transport,
                      %Notifications.DollarProgress{params: %{value: %{kind: "begin"}}}}

      :ok = Project.Progress.complete(project, token, message: "Complete!")

      assert_receive {:transport,
                      %Notifications.DollarProgress{params: %{token: ^token, value: value}}}

      assert value.kind == "end"
      assert value.message == "Complete!"
    end

    test "complete/3 with unknown ref returns :ok (no-op)", %{project: project} do
      result = Project.Progress.complete(project, :nonexistent_ref, message: "test")
      assert result == :ok
    end

    test "full manual workflow with server-initiated progress", %{project: project} do
      # Begin
      {:ok, token} = Project.Progress.begin(project, "Indexing", percentage: 0)

      assert_receive {:transport,
                      %Requests.WindowWorkDoneProgressCreate{params: %{token: ^token}}}

      assert_receive {:transport,
                      %Notifications.DollarProgress{params: %{token: ^token, value: value}}}

      assert value.kind == "begin"
      assert value.percentage == 0

      # Report multiple updates (cast, returns :ok)
      for i <- [25, 50, 75] do
        :ok = Project.Progress.report(project, token, message: "#{i}%", percentage: i)

        assert_receive {:transport,
                        %Notifications.DollarProgress{params: %{token: ^token, value: value}}}

        assert value.kind == "report"
        assert value.percentage == i
      end

      # End
      :ok = Project.Progress.complete(project, token, message: "Indexed!")

      assert_receive {:transport,
                      %Notifications.DollarProgress{params: %{token: ^token, value: value}}}

      assert value.kind == "end"
      assert value.message == "Indexed!"
    end
  end
end
