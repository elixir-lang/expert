defmodule Forge.Progress do
  @moduledoc """
  Behaviour for progress reporting.

  ## Usage

      defmodule MyProgress do
        use Forge.Progress

        @impl true
        def begin(title, opts), do: ...

        @impl true
        def report(token, opts), do: ...

        @impl true
        def complete(token, opts), do: ...
      end
  """

  @type token :: integer() | String.t()
  @type work_result :: {:done, term()} | {:done, term(), String.t()} | {:cancel, term()}

  @callback begin(title :: String.t(), opts :: keyword()) :: {:ok, token()} | {:error, :rejected}
  @callback report(token :: token(), opts :: keyword()) :: :ok
  @callback complete(token :: token(), opts :: keyword()) :: :ok

  defmacro __using__(_opts) do
    quote do
      @behaviour Forge.Progress

      alias Forge.Progress.Tracker

      @noop_token nil

      def noop_token, do: @noop_token

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
        run_with_progress(title, opts, work_fn)
      end

      @doc """
      Wraps work with tracked progress reporting via an ephemeral GenServer.

      Safely handles concurrent updates and fires a callback on each update.
      Useful when you need to track progress across concurrent tasks.

      The work function receives a `report` function that accepts:
      - `:message` - Status message
      - `:add` - Amount to increment the counter

      Uses a default callback that reports percentage-based progress.
      """
      def with_tracked_progress(title, total, work_fn) when is_function(work_fn, 1) do
        with_tracked_progress(title, total, work_fn, &default_report/4)
      end

      def with_tracked_progress(title, total, work_fn, report_fn)
          when is_function(work_fn, 1) and is_function(report_fn, 4) do
        run_with_progress(title, [percentage: 0], fn token ->
          {:ok, tracker} = Tracker.start_link(token: token, total: total, report_fn: report_fn)

          try do
            work_fn.(fn opts -> Tracker.add(tracker, Keyword.get(opts, :add, 0), opts) end)
          after
            Tracker.stop(tracker)
          end
        end)
      end

      defp run_with_progress(title, opts, work_fn) do
        case begin(title, opts) do
          {:ok, token} -> execute_work(token, work_fn)
          {:error, :rejected} -> elem(work_fn.(@noop_token), 1)
        end
      end

      defp execute_work(token, work_fn) do
        token |> work_fn.() |> complete_with(token)
      rescue
        e ->
          complete(token, message: "Error: #{Exception.message(e)}")
          reraise e, __STACKTRACE__
      end

      defp complete_with({:done, result}, token) do
        complete(token, [])
        result
      end

      defp complete_with({:done, result, msg}, token) do
        complete(token, message: msg)
        result
      end

      defp complete_with({:cancel, result}, token) do
        complete(token, message: "Cancelled")
        result
      end

      defp default_report(message, current, total, token) do
        percentage = if total > 0, do: min(100, div(current * 100, total)), else: 0
        report(token, message: message, percentage: percentage)
      end

      defoverridable with_progress: 2,
                     with_progress: 3,
                     with_tracked_progress: 3,
                     with_tracked_progress: 4
    end
  end
end
