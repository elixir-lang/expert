defmodule Engine.Progress do
  @moduledoc """
  LSP progress reporting for engine operations.
  """

  use Forge.Progress

  alias Engine.Dispatch

  import Forge.EngineApi.Messages

  @type label :: String.t()
  @type message :: String.t()
  @type delta :: pos_integer()
  @type on_complete_callback :: (-> any())
  @type report_progress_callback :: (delta(), message() -> any())

  @impl true
  def begin(title, opts \\ []) when is_list(opts) do
    Dispatch.erpc_call(Expert.Progress, :begin, [title, opts])
  end

  @impl true
  def report(@noop_token, _opts), do: :ok

  def report(token, [_ | _] = opts) when is_token(token) do
    Dispatch.erpc_cast(Expert.Progress, :report, [token, opts])
    :ok
  end

  @impl true
  def complete(token, opts \\ [])

  def complete(@noop_token, _opts), do: :ok

  def complete(token, opts) when is_token(token) and is_list(opts) do
    Dispatch.erpc_cast(Expert.Progress, :complete, [token, opts])
    :ok
  end

  @doc """
  Begins a percent-based progress operation.

  Returns a tuple of `{report_progress_callback, on_complete_callback}` that can
  be used to report progress and signal completion.

  ## Parameters

  - `label` - The label/title for the progress
  - `max` - The maximum value (total number of operations)

  ## Example

      {report_progress, on_complete} = Progress.begin_percent("Renaming", 10)
      report_progress.(1, "Processing file...")
      on_complete.()
  """
  @spec begin_percent(label(), pos_integer()) ::
          {report_progress_callback(), on_complete_callback()}
  def begin_percent(label, max) do
    Engine.broadcast(percent_progress(label: label, max: max, stage: :begin))

    report_progress = fn delta, message ->
      Engine.broadcast(
        percent_progress(label: label, message: message, delta: delta, stage: :report)
      )
    end

    complete = fn ->
      Engine.broadcast(percent_progress(label: label, stage: :complete))
    end

    {report_progress, complete}
  end
end
