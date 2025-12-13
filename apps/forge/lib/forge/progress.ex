defmodule Forge.Progress do
  @moduledoc """
  Behaviour and shared implementations for progress reporting.

  This module defines callbacks for progress reporting and provides shared
  implementations of `with_progress` and `with_tracked_progress` that work
  with any module implementing the behaviour.

  ## Implementing the behaviour

      defmodule MyProgress do
        use Forge.Progress

        @impl Forge.Progress
        def begin(title, opts), do: # ...

        @impl Forge.Progress
        def report(token, opts), do: # ...

        @impl Forge.Progress
        def complete(token, opts), do: # ...
      end

  The `use Forge.Progress` macro automatically:
  - Sets `@behaviour Forge.Progress`
  - Defines `with_progress/2`, `with_progress/3`
  - Defines `with_tracked_progress/3`, `with_tracked_progress/4`
  """

  defmacro __using__(_opts) do
    quote do
      @behaviour Forge.Progress

      alias Forge.Progress.Tracker

      defguardp is_token(token) when is_binary(token) or is_integer(token)

      @doc """
      Wraps work with progress reporting.

      The `work_fn` receives the progress token and should return one of:
      - `{:done, result}` - Operation completed successfully
      - `{:done, result, message}` - Completed with a final message
      - `{:cancel, result}` - Operation was cancelled

      ## Options

      - `:message` - Initial status message (optional)
      - `:percentage` - Initial percentage 0-100 (optional)
      - `:cancellable` - Whether the client can cancel (default: false)
      """
      def with_progress(title, work_fn, opts \\ []) when is_function(work_fn, 1) do
        opts = Keyword.validate!(opts, [:message, :percentage, :cancellable])

        case begin(title, opts) do
          {:ok, token} ->
            try do
              case work_fn.(token) do
                {:done, result} ->
                  complete(token, [])
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

          {:error, :rejected} ->
            case work_fn.(0) do
              {:done, result} -> result
              {:done, result, _message} -> result
              {:cancel, result} -> result
            end
        end
      end

      @doc """
      Wraps work with tracked progress reporting via an ephemeral GenServer.

      This is useful when you need to track progress across concurrent tasks.
      The GenServer safely handles concurrent updates and fires a callback on each update.

      The work function receives a `report` function that accepts:
      - `:message` - Status message
      - `:add` - Amount to increment the counter

      Uses a default callback that reports percentage-based progress.
      """
      def with_tracked_progress(title, total, work_fn) do
        with_tracked_progress(title, total, work_fn, fn message, current, total, token ->
          percentage = if total > 0, do: min(100, div(current * 100, total)), else: 0
          report(token, message: message, percentage: percentage)
        end)
      end

      @doc """
      Wraps work with tracked progress reporting using a custom report callback.

      The `report_fn` callback is invoked on each update with:
      - `message` - The status message (or nil)
      - `current` - The current progress value
      - `total` - The total value representing 100%
      - `token` - The progress token for reporting to LSP
      """
      def with_tracked_progress(title, total, work_fn, report_fn)
          when is_function(work_fn, 1) and is_function(report_fn, 4) do
        case begin(title, percentage: 0) do
          {:ok, token} ->
            {:ok, tracker} = Tracker.start_link(token: token, total: total, report_fn: report_fn)

            report_update = fn opts ->
              delta = Keyword.get(opts, :add, 0)
              Tracker.add(tracker, delta, opts)
            end

            try do
              case work_fn.(report_update) do
                {:done, result} ->
                  complete(token, [])
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
            after
              Tracker.stop(tracker)
            end

          {:error, :rejected} ->
            case work_fn.(fn _opts -> :ok end) do
              {:done, result} -> result
              {:done, result, _message} -> result
              {:cancel, result} -> result
            end
        end
      end

      defoverridable with_progress: 2,
                     with_progress: 3,
                     with_tracked_progress: 3,
                     with_tracked_progress: 4
    end
  end

  @type token :: integer() | String.t()
  @type work_result :: {:done, term()} | {:done, term(), String.t()} | {:cancel, term()}
  @type work_fn :: (token() -> work_result())
  @type tracked_work_fn :: ((keyword() -> :ok) -> work_result())
  @type report_callback :: (String.t() | nil, non_neg_integer(), pos_integer(), token() -> any())

  @doc """
  Begins a progress sequence with the given title.

  Returns `{:ok, token}` on success or `{:error, :rejected}` if the client rejects the progress request.

  ## Options

  - `:message` - Initial status message
  - `:percentage` - Initial percentage 0-100
  - `:cancellable` - Whether the client can cancel
  - `:token` - Custom token to use (caller ensures uniqueness)
  """
  @callback begin(title :: String.t(), opts :: keyword()) :: {:ok, token()} | {:error, :rejected}

  @doc """
  Reports progress for an in-progress operation.

  ## Options

  - `:message` - Status message to display
  - `:percentage` - Progress percentage 0-100
  """
  @callback report(token :: token(), opts :: keyword()) :: :ok

  @doc """
  Completes a progress sequence.

  ## Options

  - `:message` - Final completion message
  """
  @callback complete(token :: token(), opts :: keyword()) :: :ok
end
