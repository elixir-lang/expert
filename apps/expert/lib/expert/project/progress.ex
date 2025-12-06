defmodule Expert.Project.Progress do
  alias Expert.Project.Progress.State
  alias Forge.Project

  use GenServer

  @type work_result :: {:done, term()} | {:done, term(), String.t()} | {:cancel, term()}
  @type work_fn :: (integer() | String.t() -> work_result())

  defguardp is_token(token) when is_binary(token) or is_integer(token)

  @doc """
  Wraps a function with server-initiated progress reporting.

  The function receives the progress token and can call `Progress.report/3` directly:

      Progress.with_server_progress(project, "Building", fn token ->
        Progress.report(project, token, message: "Compiling...")
        compile()
        {:done, :ok, "Build complete"}
      end)

  ## Options

  * `:message` - Initial status message (optional)
  * `:percentage` - Initial percentage 0-100 (optional)
  * `:cancellable` - Whether the client can cancel (default: false)
  """
  @spec with_server_progress(Project.t(), String.t(), work_fn(), keyword()) :: term()
  def with_server_progress(project, title, func, opts \\ []) when is_function(func, 1) do
    opts = Keyword.validate!(opts, [:message, :percentage, :cancellable])
    {:ok, token} = begin(project, title, opts)
    run_work(project, token, func)
  end

  @doc """
  Wraps a function with client-initiated progress reporting, and closes it on completion.

  The function receives the progress token and can call `Progress.report/3` directly:

      Progress.with_client_progress(project, client_token, fn token ->
        Progress.report(project, token, message: "Compiling...")
        compile()
        {:done, :ok, "Build complete"}
      end)
  """
  @spec with_client_progress(Project.t(), integer() | String.t(), work_fn()) :: term()
  def with_client_progress(project, client_token, func)
      when is_function(func, 1) and is_token(client_token) do
    :ok = register(project, client_token)
    run_work(project, client_token, func)
  end

  defp run_work(project, token, func) do
    try do
      case func.(token) do
        {:done, result} ->
          complete(project, token, [])
          result

        {:done, result, message} ->
          complete(project, token, message: message)
          result

        {:cancel, result} ->
          complete(project, token, message: "Cancelled")
          result
      end
    rescue
      e ->
        complete(project, token, message: "Error: #{Exception.message(e)}")
        reraise e, __STACKTRACE__
    end
  end

  @doc """
  Manually registers a client-initiated progress token.

  ## Options

  * `:ref` - An atom to use as a stable identifier for this progress (optional).

  ## Examples

      :ok = Progress.register(project, client_work_token, ref: :initialize)
  """
  @spec register(Project.t(), integer() | String.t(), keyword()) :: :ok
  def register(project, client_token, opts \\ []) do
    GenServer.call(name(project), {:register, client_token, opts})
  end

  @doc """
  Manually begins a server-initiated progress.

  ## Options

  * `:message` - Initial status message (optional)
  * `:percentage` - Initial percentage 0-100 (optional)
  * `:cancellable` - Whether the client can cancel (default: false)

  ## Examples

      {:ok, work_done_token} = Progress.begin(project, "Building", message: "Starting...")
  """
  @spec begin(Project.t(), String.t(), keyword()) :: {:ok, integer()} | {:error, :rejected}
  def begin(project, title, opts \\ []) do
    GenServer.call(name(project), {:begin, title, opts})
  end

  @doc """
  Reports progress update (fire-and-forget).

  This is a cast operation - it returns immediately without waiting for confirmation.
  If the token/ref doesn't exist, the update is silently ignored with a warning log.

  ## Options

  * `:message` - Status message (optional)
  * `:percentage` - Percentage 0-100 (optional)

  ## Examples

      Progress.report(project, :initialize, message: "Loading...")
      Progress.report(project, work_done_token, message: "Processing...", percentage: 50)
  """
  @spec report(Project.t(), atom() | integer() | String.t(), keyword()) :: :ok
  def report(project, token_or_ref, opts \\ []) do
    GenServer.cast(name(project), {:report, token_or_ref, opts})
  end

  @doc """
  Manually ends a progress token.

  ## Options

  * `:message` - Final message, typically indicating some outcome (optional).

  ## Examples

      :ok = Progress.complete(project, work_done_token, message: "Done!")
      :ok = Progress.complete(project, :initialize, message: "Ready")
  """
  @spec complete(Project.t(), atom() | integer() | String.t(), keyword()) :: :ok
  def complete(project, token_or_ref, opts \\ []) do
    GenServer.call(name(project), {:end, token_or_ref, opts})
  end

  # GenServer API

  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, project, name: name(project))
  end

  def child_spec(%Project{} = project) do
    %{
      id: {__MODULE__, Project.name(project)},
      start: {__MODULE__, :start_link, [project]}
    }
  end

  @impl GenServer
  def init(project) do
    state = State.new(project)

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:register, token, opts}, _from, %State{} = state) when is_token(token) do
    {:ok, new_state} = State.register(state, token, opts)
    {:reply, :ok, new_state}
  end

  def handle_call({:begin, title, opts}, _from, %State{} = state) do
    case State.begin(state, title, opts) do
      {:ok, token, new_state} -> {:reply, {:ok, token}, new_state}
      {:error, :rejected} -> {:reply, {:error, :rejected}, state}
    end
  end

  def handle_call({:end, token, opts}, _from, %State{} = state) when is_token(token) do
    case State.complete(state, token, opts) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, :unknown_token, state} -> {:reply, :ok, state}
    end
  end

  def handle_call({:end, ref, opts}, _from, %State{} = state) when is_atom(ref) do
    case State.complete(state, ref, opts) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, :unknown_ref} -> {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_cast({:report, token_or_ref, opts}, %State{} = state) do
    case State.report(state, token_or_ref, opts) do
      {:ok, _token, new_state} -> {:noreply, new_state}
      {:noop, state} -> {:noreply, state}
    end
  end

  # Engine Node handlers

  @impl true
  def handle_info({:engine_progress_begin, token, title, opts}, %State{} = state) do
    case State.register_engine_token(state, token, title, opts) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, :rejected} -> {:noreply, state}
    end
  end

  def handle_info({:engine_progress_report, token, updates}, %State{} = state) do
    case State.report(state, token, updates) do
      {:ok, _token, new_state} -> {:noreply, new_state}
      {:noop, state} -> {:noreply, state}
    end
  end

  def handle_info({:engine_progress_complete, token_or_ref, opts}, %State{} = state) do
    case State.complete(state, token_or_ref, opts) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, :unknown_token, state} -> {:noreply, state}
      {:error, :unknown_ref} -> {:noreply, state}
    end
  end

  def name(%Project{} = project), do: :"#{Project.name(project)}::progress"

  def whereis(%Project{} = project), do: project |> name() |> Process.whereis()
end
