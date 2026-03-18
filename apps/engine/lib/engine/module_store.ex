defmodule Engine.ModuleStore do
  use GenServer

  import Forge.EngineApi.Messages

  alias ElixirSense.Providers.Plugins.ModuleStore
  alias Engine.Dispatch
  alias Engine.Progress

  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    Dispatch.register_listener(self(), project_compiled())
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(project_compiled(), state) do
    Progress.with_progress("Finding Completion Candidates", fn token ->
      ModuleStore.build()
      {:done, token}
    end)

    {:stop, :normal, state}
  end
end
