defmodule Expert.Progress do
  @moduledoc """
  Stateless progress reporting for LSP work-done progress.

  This module provides a simple API for reporting progress to the language client.
  It is stateless - callers are responsible for managing their own tokens. When a
  request handler process dies (e.g., due to cancellation), any tokens it held
  naturally go away without explicit cleanup.

  ## Server-initiated progress

      {:ok, token} = Progress.begin("Building project")
      Progress.report(token, message: "Compiling...")
      Progress.complete(token, message: "Done")

  Or use the convenience wrapper:

      Progress.with_progress("Building", fn token ->
        Progress.report(token, message: "Working...")
        {:done, result}
      end)

  ## Client-initiated progress

  When the client provides a workDoneToken with a request:

      Progress.with_client_progress(client_token, fn token ->
        Progress.report(token, message: "Processing...")
        {:done, result}
      end)
  """

  alias Expert.Configuration
  alias Expert.Protocol.Id
  alias GenLSP.{Notifications, Requests, Structures}

  require Logger

  @type token :: integer() | String.t()
  @type work_result :: {:done, term()} | {:done, term(), String.t()} | {:cancel, term()}
  @type work_fn :: (token() -> work_result())

  defguardp is_token(token) when is_binary(token) or is_integer(token)

  @doc """
  Begins server-initiated progress.

  Generates a token, requests the client create the progress indicator,
  and sends the begin notification.

  ## Options

  * `:message` - Initial status message (optional)
  * `:percentage` - Initial percentage 0-100 (optional)
  * `:cancellable` - Whether the client can cancel (default: false)

  ## Examples

      {:ok, token} = Progress.begin("Building project")
      {:ok, token} = Progress.begin("Indexing", message: "Starting...", percentage: 0)
  """
  @spec begin(String.t(), keyword()) :: {:ok, integer()} | {:error, :rejected}
  def begin(title, opts \\ []) do
    opts = Keyword.validate!(opts, [:message, :percentage, :cancellable])
    token = System.unique_integer([:positive])

    if Configuration.client_supports?(:work_done_progress) do
      case request_work_done_progress(token) do
        :ok ->
          notify_begin(token, title, opts)
          {:ok, token}

        {:error, reason} ->
          Logger.warning("Client rejected progress token: #{inspect(reason)}")
          {:error, :rejected}
      end
    else
      {:ok, -1}
    end
  end

  @doc """
  Reports progress update.

  ## Options

  * `:message` - Status message (optional)
  * `:percentage` - Percentage 0-100 (optional)

  ## Examples

      Progress.report(token, message: "Processing file 1...")
      Progress.report(token, message: "Halfway there", percentage: 50)
  """
  @spec report(token(), keyword()) :: :ok
  def report(token, opts \\ [])

  def report(-1, _opts), do: :ok

  def report(token, opts) when is_token(token) do
    notify_report(token, opts)

    :ok
  end

  @doc """
  Ends a progress sequence.

  ## Options

  * `:message` - Final completion message (optional)

  ## Examples

      Progress.complete(token)
      Progress.complete(token, message: "Build complete")
  """
  @spec complete(token(), keyword()) :: :ok
  def complete(token, opts \\ [])

  def complete(-1, _opts), do: :ok

  def complete(token, opts) when is_token(token) do
    notify_end(token, opts)
    :ok
  end

  @doc """
  Wraps a function with server-initiated progress reporting.

  The function receives the progress token and can call `Progress.report/2` directly.

  ## Return values

  * `{:done, result}` - Operation completed successfully
  * `{:done, result, message}` - Completed with a final message
  * `{:cancel, result}` - Operation was cancelled

  ## Options

  * `:message` - Initial status message (optional)
  * `:percentage` - Initial percentage 0-100 (optional)
  * `:cancellable` - Whether the client can cancel (default: false)

  ## Examples

      Progress.with_progress("Building", fn token ->
        Progress.report(token, message: "Compiling...")
        {:done, :ok, "Build complete"}
      end)
  """
  @spec with_progress(String.t(), work_fn(), keyword()) :: term()
  def with_progress(title, func, opts \\ []) when is_function(func, 1) do
    case begin(title, opts) do
      {:ok, token} ->
        run_work(token, func)

      {:error, :rejected} ->
        # Client rejected the progress token, but we still run the work
        # Just pass a dummy token that won't send notifications
        case func.(0) do
          {:done, result} -> result
          {:done, result, _message} -> result
          {:cancel, result} -> result
        end
    end
  end

  @doc """
  Wraps a function with client-initiated progress reporting.

  Similar to `with_progress/3` but uses a token provided by the client.
  """
  @spec with_client_progress(token(), work_fn()) :: term()
  def with_client_progress(token, func) when is_function(func, 1) and is_token(token) do
    run_work(token, func)
  end

  defp run_work(token, func) do
    try do
      case func.(token) do
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

  defp request_work_done_progress(token) do
    Expert.get_lsp()
    |> GenLSP.request(%Requests.WindowWorkDoneProgressCreate{
      id: Id.next(),
      params: %Structures.WorkDoneProgressCreateParams{token: token}
    })
    |> case do
      nil -> :ok
      error -> {:error, error}
    end
  end

  defp notify_begin(token, title, opts) do
    lsp = Expert.get_lsp()

    GenLSP.notify(lsp, %Notifications.DollarProgress{
      params: %Structures.ProgressParams{
        token: token,
        value: %Structures.WorkDoneProgressBegin{
          kind: "begin",
          title: title,
          message: Keyword.get(opts, :message),
          percentage: Keyword.get(opts, :percentage),
          cancellable: Keyword.get(opts, :cancellable)
        }
      }
    })
  end

  defp notify_report(token, updates) do
    lsp = Expert.get_lsp()

    GenLSP.notify(lsp, %Notifications.DollarProgress{
      params: %Structures.ProgressParams{
        token: token,
        value: %Structures.WorkDoneProgressReport{
          kind: "report",
          message: Keyword.get(updates, :message),
          percentage: Keyword.get(updates, :percentage)
        }
      }
    })
  end

  defp notify_end(token, opts) do
    lsp = Expert.get_lsp()

    GenLSP.notify(lsp, %Notifications.DollarProgress{
      params: %Structures.ProgressParams{
        token: token,
        value: %Structures.WorkDoneProgressEnd{
          kind: "end",
          message: Keyword.get(opts, :message)
        }
      }
    })
  end
end
