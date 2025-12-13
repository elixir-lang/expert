defmodule Expert.Progress do
  @moduledoc """
  LSP progress reporting for the Expert language server.
  """

  use Forge.Progress

  alias Expert.Configuration
  alias Expert.Protocol.Id
  alias GenLSP.{Notifications, Requests, Structures}

  require Logger

  @noop_token Forge.Progress.noop_token()

  # Behaviour implementations

  @doc """
  Begins server-initiated progress.

  Generates a token, requests the client create the progress indicator,
  and sends the begin notification.

  ## Options

  * `:message` - Initial status message (optional)
  * `:percentage` - Initial percentage 0-100 (optional)
  * `:cancellable` - Whether the client can cancel (default: false)
  * `:token` - Custom token to use (caller ensures uniqueness)

  ## Examples

      {:ok, token} = Progress.begin("Building project")
      {:ok, token} = Progress.begin("Indexing", message: "Starting...", percentage: 0)
      {:ok, token} = Progress.begin("Custom", token: my_unique_token)
  """
  @impl Forge.Progress
  def begin(title, opts \\ []) do
    opts = Keyword.validate!(opts, [:message, :percentage, :cancellable, :token])

    token = opts[:token] || System.unique_integer([:positive])

    if Configuration.client_support(:work_done_progress) do
      case request_work_done_progress(token) do
        :ok ->
          notify(token, progress_begin(title, opts))
          {:ok, token}

        {:error, reason} ->
          Logger.warning("Client rejected progress token: #{inspect(reason)}")
          {:error, :rejected}
      end
    else
      {:ok, @noop_token}
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
  @impl Forge.Progress
  def report(@noop_token, _opts), do: :ok

  def report(token, opts) when is_token(token) do
    notify(token, progress_report(opts))
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
  @impl Forge.Progress
  def complete(token, opts \\ [])

  def complete(@noop_token, _opts), do: :ok

  def complete(token, opts) when is_token(token) do
    notify(token, progress_end(opts))
    :ok
  end

  # Private helpers

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

  defp notify(token, value) do
    GenLSP.notify(Expert.get_lsp(), %Notifications.DollarProgress{
      params: %Structures.ProgressParams{token: token, value: value}
    })
  end

  defp progress_begin(title, opts) do
    %Structures.WorkDoneProgressBegin{
      kind: "begin",
      title: title,
      message: opts[:message],
      percentage: opts[:percentage],
      cancellable: opts[:cancellable]
    }
  end

  defp progress_report(opts) do
    %Structures.WorkDoneProgressReport{
      kind: "report",
      message: opts[:message],
      percentage: opts[:percentage]
    }
  end

  defp progress_end(opts) do
    %Structures.WorkDoneProgressEnd{kind: "end", message: opts[:message]}
  end
end
