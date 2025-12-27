defmodule Forge.Progress.Tracker do
  @moduledoc """
  Ephemeral GenServer for tracking progress across concurrent tasks.

  This module provides a stateful progress tracker that can be safely
  updated from multiple concurrent processes (e.g., Task.async_stream).
  It fires a callback on each update to report progress to the LSP client.

  Use via `Forge.Progress.with_tracked_progress/4,5` rather than directly.
  """

  use GenServer

  defstruct [:token, :total, :current, :report_fn]

  # Client API

  @doc """
  Starts a tracker process.

  ## Options

  - `:token` - The progress token (required)
  - `:total` - The total value representing 100% (required)
  - `:report_fn` - Callback invoked on each update (required)
    Signature: `(message, current, total, token) -> any()`
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Adds delta to the current progress and fires the report callback.

  ## Options

  - `:message` - Status message to pass to the callback
  """
  def add(tracker, delta, opts \\ []), do: GenServer.cast(tracker, {:add, delta, opts})

  @doc """
  Stops the tracker process.
  """
  def stop(tracker), do: GenServer.stop(tracker, :normal)

  # Server callbacks

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      token: Keyword.fetch!(opts, :token),
      total: Keyword.fetch!(opts, :total),
      current: 0,
      report_fn: Keyword.fetch!(opts, :report_fn)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:add, delta, opts}, state) do
    new_current = state.current + delta
    message = Keyword.get(opts, :message)

    state.report_fn.(message, new_current, state.total, state.token)

    {:noreply, %{state | current: new_current}}
  end
end
