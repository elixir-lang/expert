defmodule Forge.Test.Quiet do
  import ExUnit.CaptureIO

  def quiet(io_device \\ :stdio, fun) do
    test_pid = self()

    capture_io(io_device, fn ->
      send(test_pid, {:result, fun.()})
    end)

    receive do
      {:result, result} -> result
    end
  end
end
