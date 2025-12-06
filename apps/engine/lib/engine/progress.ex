defmodule Engine.Progress do
  @moduledoc """
  LSP progress reporting for engine operations.
  """

  alias Engine.Dispatch

  @type work_result :: {:done, term()} | {:done, term(), String.t()} | {:cancel, term()}
  @type work_fn :: (integer() -> work_result())

  @doc """
  Wraps work with progress reporting.

  The `work_fn` receives the progress token and can call `Progress.report/2` directly:

      with_progress("Indexing", fn token ->
        Progress.report(token, message: "Processing...")
        do_work()
        {:done, :ok}
      end)

  The `work_fn` must return one of:
  - `{:done, result}` - Operation completed successfully
  - `{:done, result, message}` - Completed with a final message
  - `{:cancel, result}` - Operation was cancelled

  ## Options

  - `:message` - Initial status message (optional)
  - `:percentage` - Initial percentage 0-100 (optional)
  - `:cancellable` - Whether the client can cancel (default: false)
  """
  @spec with_progress(String.t(), work_fn(), keyword()) :: term()
  def with_progress(title, work_fn, opts \\ []) when is_function(work_fn, 1) do
    opts = Keyword.validate!(opts, [:message, :percentage, :cancellable])

    token = begin(title, opts)

    try do
      case work_fn.(token) do
        {:done, result} ->
          complete(token)
          result

        {:done, result, message} ->
          complete(token, message: message)
          result

        {:cancel, result} ->
          complete(token, message: "Cancelled")
          result
      end
    rescue
      e ->
        complete(token, message: "Error: #{Exception.message(e)}")
        reraise e, __STACKTRACE__
    end
  end

  @doc """
  Manually begins a progress sequence with the given title.

  Generates a token internally and returns it for use with subsequent
  `report/2` and `complete/2` calls.

  ## Options

  - `:message` - Initial status message
  - `:percentage` - Initial percentage 0-100
  - `:cancellable` - Whether the client can cancel
  """
  @spec begin(String.t(), keyword()) :: integer()
  def begin(title, opts \\ []) do
    # TODO: BAD.
    case Dispatch.rpc_call(Expert.Progress, :begin, [title, opts]) do
      {:ok, token} -> token
      _ -> -1
    end
  end

  @doc """
  Reports progress for an in-progress operation.

  ## Options

  - `:message` - Status message to display
  - `:percentage` - Progress percentage 0-100
  """
  @spec report(integer(), keyword()) :: :ok
  def report(token, updates \\ []) when is_integer(token) do
    Dispatch.rpc_cast(Expert.Progress, :report, [token, updates])
    :ok
  end

  @doc """
  Completes a progress sequence.

  ## Options

  - `:message` - Final completion message
  """
  @spec complete(integer(), keyword()) :: :ok
  def complete(token, opts \\ []) when is_integer(token) do
    Dispatch.rpc_cast(Expert.Progress, :complete, [token, opts])
    :ok
  end
end
