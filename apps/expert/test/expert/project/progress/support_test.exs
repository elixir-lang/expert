defmodule Expert.Project.Progress.SupportTest do
  alias Expert.Project.Progress

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  use ExUnit.Case
  use Patch
  use Progress.Support

  setup do
    test_pid = self()
    patch(Progress, :name, fn _ -> test_pid end)
    :ok
  end

  test "it should send begin/complete event and return the result" do
    result = with_progress project(), "act", fn -> :ok end

    assert result == :ok
    assert_received project_progress(label: "act", stage: :begin)
    assert_received project_progress(label: "act", stage: :complete)
  end

  test "it should send begin/complete event even there is an exception" do
    assert_raise(Mix.Error, fn ->
      with_progress project(), "start", fn -> raise Mix.Error, "can't start" end
    end)

    assert_received project_progress(label: "start", stage: :begin)
    assert_received project_progress(label: "start", stage: :complete)
  end
end
