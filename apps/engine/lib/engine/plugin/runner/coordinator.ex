defmodule Engine.Plugin.Runner.Coordinator do
  @moduledoc false

  alias Engine.Plugin.Runner.Coordinator.State
  alias Forge.Formats

  require Logger
  use GenServer

  def run_all(subject, plugin_type, on_complete, timeout) when is_function(on_complete, 1) do
    GenServer.call(__MODULE__, {:run_all, subject, plugin_type, on_complete, timeout})
  end

  # GenServer callbacks

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    {:ok, State.new()}
  end

  @impl GenServer
  def handle_call({:run_all, subject, plugin_type, on_complete, timeout}, _from, %State{} = state) do
    {elapsed_us, {results, new_state}} =
      :timer.tc(State, :run_all, [state, subject, plugin_type, timeout])

    Logger.info("Plugins found #{length(results)} results in #{Formats.time(elapsed_us)}")

    on_complete.(results)
    {:reply, :ok, new_state}
  end
end
