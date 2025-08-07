defmodule Engine.Build.Isolation do
  @moduledoc """
  Runs functions in an isolated, monitored process
  """

  @spec invoke((-> term())) :: {:ok, term()} | {:error, term()}
  def invoke(function) when is_function(function, 0) do
    me = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(me, {:result, function.()})
      end)

    receive do
      {:result, result} ->
        # clean up the DOWN message from the above process in the mailbox.
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, reason}
    end
  end
end
