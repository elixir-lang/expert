defmodule Expert.Project.ProgressTest do
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Expert.Project
  alias Expert.Test.DispatchFake
  alias GenLSP.Notifications
  alias GenLSP.Requests
  alias GenLSP.Structures

  import Forge.Test.Fixtures
  import Forge.EngineApi.Messages
  import Expert.Test.Protocol.TransportSupport

  use ExUnit.Case
  use Patch
  use DispatchFake
  use Forge.Test.EventualAssertions

  setup do
    project = project()
    pid = start_supervised!({Project.Progress, project})
    DispatchFake.start()
    Engine.Dispatch.register_listener(pid, project_progress())
    Engine.Dispatch.register_listener(pid, percent_progress())

    {:ok, project: project}
  end

  def percent_begin(project, label, max) do
    message = percent_progress(stage: :begin, label: label, max: max)
    EngineApi.broadcast(project, message)
  end

  defp percent_report(project, label, delta, message \\ nil) do
    message = percent_progress(stage: :report, label: label, message: message, delta: delta)
    EngineApi.broadcast(project, message)
  end

  defp percent_complete(project, label, message) do
    message = percent_progress(stage: :complete, label: label, message: message)
    EngineApi.broadcast(project, message)
  end

  def progress(stage, label, message \\ "") do
    project_progress(label: label, message: message, stage: stage)
  end

  def with_work_done_progress_support(_) do
    patch(Configuration, :client_supports?, fn :work_done_progress -> true end)
    :ok
  end

  describe "report the progress message" do
    setup [:with_patched_transport]

    test "it should be able to send the report progress", %{project: project} do
      patch(Configuration, :client_supports?, fn :work_done_progress -> true end)

      begin_message = progress(:begin, "mix compile")
      EngineApi.broadcast(project, begin_message)

      assert_receive {:transport,
                      %Requests.WindowWorkDoneProgressCreate{
                        params: %Structures.WorkDoneProgressCreateParams{token: token}
                      }}

      assert_receive {:transport, %Notifications.DollarProgress{}}

      report_message = progress(:report, "mix compile", "lib/file.ex")
      EngineApi.broadcast(project, report_message)

      assert_receive {:transport,
                      %Notifications.DollarProgress{
                        params: %Structures.ProgressParams{token: ^token, value: value}
                      }}

      assert value.kind == "report"
      assert value.message == "lib/file.ex"
      assert value.percentage == nil
      assert value.cancellable == nil
    end

    test "it should write nothing when the client does not support work done", %{project: project} do
      patch(Configuration, :client_supports?, fn :work_done_progress -> false end)

      begin_message = progress(:begin, "mix compile")
      EngineApi.broadcast(project, begin_message)

      refute_receive {:transport, %Requests.WindowWorkDoneProgressCreate{params: %{}}}
    end
  end

  describe "reporting a percentage progress" do
    setup [:with_patched_transport, :with_work_done_progress_support]

    test "it should be able to increment the percentage", %{project: project} do
      percent_begin(project, "indexing", 400)

      assert_receive {:transport, %Requests.WindowWorkDoneProgressCreate{params: %{token: token}}}
      assert_receive {:transport, %Notifications.DollarProgress{} = progress}

      assert progress.params.value.kind == "begin"
      assert progress.params.value.title == "indexing"
      assert progress.params.value.percentage == 0

      percent_report(project, "indexing", 100)

      assert_receive {:transport,
                      %Notifications.DollarProgress{
                        params: %Structures.ProgressParams{token: ^token, value: value}
                      }}

      assert value.kind == "report"
      assert value.percentage == 25
      assert value.message == nil

      percent_report(project, "indexing", 260, "Almost done")

      assert_receive {:transport,
                      %Notifications.DollarProgress{params: %{token: ^token, value: value}}}

      assert value.percentage == 90
      assert value.message == "Almost done"

      percent_complete(project, "indexing", "Indexing Complete")

      assert_receive {:transport,
                      %Notifications.DollarProgress{params: %{token: ^token, value: value}}}

      assert value.kind == "end"
      assert value.message == "Indexing Complete"
    end

    test "it caps the percentage at 100", %{project: project} do
      percent_begin(project, "indexing", 100)
      percent_report(project, "indexing", 1000)

      assert_receive {:transport,
                      %Notifications.DollarProgress{params: %{value: %{kind: "begin"}}}}

      assert_receive {:transport, %Notifications.DollarProgress{params: %{value: value}}}
      assert value.kind == "report"
      assert value.percentage == 100
    end

    test "it only allows the percentage to grow", %{project: project} do
      percent_begin(project, "indexing", 100)

      assert_receive {:transport,
                      %Notifications.DollarProgress{params: %{value: %{kind: "begin"}}}}

      percent_report(project, "indexing", 10)

      assert_receive {:transport, %Notifications.DollarProgress{params: %{value: value}}}
      assert value.kind == "report"
      assert value.percentage == 10

      percent_report(project, "indexing", -10)
      assert_receive {:transport, %Notifications.DollarProgress{params: %{value: value}}}
      assert value.kind == "report"
      assert value.percentage == 10

      percent_report(project, "indexing", 5)
      assert_receive {:transport, %Notifications.DollarProgress{params: %{value: value}}}
      assert value.kind == "report"
      assert value.percentage == 15
    end
  end
end
