defmodule Forge.EPMD do
  @moduledoc false

  # From Erlang/OTP 23+
  @epmd_dist_version 6

  @doc ~S"""
  This is the distribution port of the current node.

  The parent node must be named `expert-manager-*`.
  The child node must be named `expert-project-*`.

  When the parent boots the child, it must pass
  its node name and port as the respective environment
  variables `EXPERT_PARENT_NODE` and `EXPERT_PARENT_PORT`.

  The parent must have this as a child in its supervision tree:

      {Forge.NodePortMapper, []}

  The child, in turn, must have this:

      {Task, &Forge.NodePortMapper.register/0}

  This will register the child within the parent, so they can
  find each other.

  ## Example

  In order to manually simulate the connections, run `elixirc epmd.ex` to compile
  this file and follow the steps below. Notice we call the functions in the
  `Forge.NodePortMapper` module directly, while in practice they will be called
  as part of the app's supervision tree.

      # In one node
      $ iex --erl "-start_epmd false -epmd_module Elixir.Forge.EPMD" --sname expert-manager-foo
      iex(expert_parent_foo@macstudio)> Forge.NodePortMapper.start_link([])
      iex(expert_parent_foo@macstudio)> Forge.EPMD.dist_port()
      52914

  Get the port name from the step above and then, in another terminal, do:

      $ EXPERT_PARENT_NODE=expert_parent_foo@macstudio EXPERT_PARENT_PORT=52914 \
          iex --erl "-start_epmd false -epmd_module Elixir.Forge.EPMD" --sname expert-project-bar
      iex> Forge.NodePortMapper.register()

  And in another terminal:

      $ EXPERT_PARENT_NODE=expert_parent_foo@macstudio EXPERT_PARENT_PORT=52914 \
          iex --erl "-start_epmd false -epmd_module Elixir.Forge.EPMD -expert parent_port 52914" --sname expert-project-baz
      iex> Forge.NodePortMapper.register()

  If you try `Node.ping(:expert-project-bar@HOSTNAME)` from the last node, it should work.
  The child nodes will find each other even without EPMD.
  """
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

  def port_please(name, host), do: port_please(name, host, :infinity)

  def port_please(~c"expert-manager-" ++ _ = name, host, timeout) do
    if port = System.get_env("EXPERT_PARENT_PORT") do
      {:port, String.to_integer(port), @epmd_dist_version}
    else
      :erl_epmd.port_please(name, host, timeout)
    end
  end

  def port_please(~c"expert-project-" ++ _ = name, host, timeout) do
    if port = Forge.NodePortMapper.get_port(List.to_atom(name)) do
      {:port, port, @epmd_dist_version}
    else
      :erl_epmd.port_please(name, host, timeout)
    end
  end

  def port_please(name, host, timeout) do
    :erl_epmd.port_please(name, host, timeout)
  end

  defdelegate start_link, to: :erl_epmd
  defdelegate listen_port_please(name, host), to: :erl_epmd
  defdelegate address_please(name, host, family), to: :erl_epmd
  defdelegate names(host_name), to: :erl_epmd
end
