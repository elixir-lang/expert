defmodule Expert.CodeIntelligence.Hex.Cache do
  @moduledoc """
  DETS-backed TTL cache for hex.pm API responses.

  The cache survives restarts so completion can serve hex packages without
  hitting the network on cold starts. Stale entries are still served when the
  upstream fetcher fails.
  """

  use GenServer, restart: :transient

  require Logger

  @type key :: term()
  @type value :: term()
  @type fetcher :: (-> {:ok, value()} | {:error, term()})

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns a value from the cache, calling `fetcher` on a miss or when the
  cached entry is older than `ttl_ms`.

  When `fetcher` returns `{:error, _}` and a stale entry exists, the stale
  value is returned instead.
  """
  @spec get_or_fetch(GenServer.server(), key(), non_neg_integer(), fetcher()) ::
          {:ok, value()} | {:error, term()}
  def get_or_fetch(server, key, ttl_ms, fetcher)
      when is_integer(ttl_ms) and ttl_ms >= 0 and is_function(fetcher, 0) do
    case GenServer.call(server, {:lookup, key}) do
      {:found, value, inserted_at} ->
        if fresh?(inserted_at, ttl_ms) do
          {:ok, value}
        else
          refresh(server, key, fetcher, value)
        end

      :miss ->
        refresh(server, key, fetcher, nil)
    end
  end

  @doc """
  Returns the currently-cached value for `key`, or `:miss` if there is none.
  Never invokes a fetcher — safe for synchronous, latency-sensitive callers
  like CodeLens that must not block on the network.
  """
  @spec peek(GenServer.server(), key()) :: {:ok, value()} | :miss
  def peek(server, key) do
    case GenServer.call(server, {:lookup, key}) do
      {:found, value, _inserted_at} -> {:ok, value}
      :miss -> :miss
    end
  end

  defp refresh(server, key, fetcher, stale_value) do
    case fetcher.() do
      {:ok, value} = ok ->
        GenServer.cast(server, {:put, key, value})
        ok

      {:error, _} = error when is_nil(stale_value) ->
        error

      {:error, _} ->
        {:ok, stale_value}
    end
  end

  defp fresh?(inserted_at, ttl_ms) do
    System.system_time(:millisecond) - inserted_at < ttl_ms
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    path = Keyword.fetch!(opts, :path)
    reset? = Keyword.get(opts, :reset?, false)

    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(name, file: String.to_charlist(path), type: :set) do
      {:ok, table} ->
        Process.flag(:trap_exit, true)
        {:ok, %{table: table}}

      {:error, reason} when not reset? ->
        Logger.warning(
          "Failed to open hex cache at #{path}: #{inspect(reason)}. Deleting and trying again"
        )

        File.rm_rf(path)
        init(Keyword.put(opts, :reset?, true))

      {:error, reason} when reset? ->
        Logger.warning("Failed to open hex cache at #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:lookup, key}, _from, %{table: table} = state) do
    reply =
      case :dets.lookup(table, key) do
        [{^key, value, inserted_at}] -> {:found, value, inserted_at}
        _ -> :miss
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_cast({:put, key, value}, %{table: table} = state) do
    :dets.insert(table, {key, value, System.system_time(:millisecond)})
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
    :ok
  end
end
