defmodule Expert.EPMD do
  def dist_port do
    :persistent_term.get(:expert_dist_port, nil)
  end

  # EPMD callbacks

  def register_node(name, port), do: register_node(name, port, :inet)

  def register_node(name, port, family) do
    :persistent_term.put(:expert_dist_port, port)

    # We don't care if EPMD is not running
    case :erl_epmd.register_node(name, port, family) do
      {:error, _} -> {:ok, -1}
      {:ok, _} = ok -> ok
    end
  end

  defdelegate start_link(), to: :erl_epmd
  defdelegate port_please(name, host), to: :erl_epmd
  defdelegate port_please(name, host, timeout), to: :erl_epmd
  defdelegate listen_port_please(name, host), to: :erl_epmd
  defdelegate address_please(name, host, family), to: :erl_epmd
  defdelegate names(host_name), to: :erl_epmd
end
