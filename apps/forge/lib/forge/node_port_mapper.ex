defmodule Forge.NodePortMapper do
  use GenServer
  require Logger

  @name __MODULE__

  def start_link(_) do
    Logger.info("Starting NodePortMapper on #{node()}")
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  defp parent_node do
    if parent_node = System.get_env("EXPERT_PARENT_NODE") do
      String.to_atom(parent_node)
    else
      node()
    end
  end

  def register do
    GenServer.call({@name, parent_node()}, {:register, node(), Forge.EPMD.dist_port()})
  end

  def get_port(node) do
    GenServer.call({@name, parent_node()}, {:get_port, node})
  end

  def init(:ok) do
    {:ok, %{}}
  end

  def handle_call({:register, node, port}, _from, state) do
    :erlang.monitor_node(node, true)
    {:reply, :ok, Map.put(state, node, port)}
  end

  def handle_call({:get_port, node}, _from, state) do
    {:reply, Map.get(state, node), state}
  end

  def handle_info({:nodedown, node}, state) do
    {:noreply, Map.delete(state, node)}
  end
end
