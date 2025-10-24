Application.ensure_all_started(:snowflake)
Application.ensure_all_started(:refactorex)

# Start EPMD for the test manager node.
# We can't use Expert.EPMD here because the kernel needs epmd_module before
# Elixir loads. In releases, Elixir is in the boot sequence. In mix test, it's not.
# Compromise: manager uses EPMD, project nodes are epmdless (see engine_node.ex).
{"", 0} = System.cmd("epmd", ~w(-daemon))

with :nonode@nohost <- Node.self() do
  random_number = :rand.uniform(500)

  {:ok, _pid} =
    :net_kernel.start(:"expert-testing-#{random_number}@127.0.0.1", %{name_domain: :longnames})
end

# Query our distribution port and store it in persistent_term
# This enables epmdless configuration for project nodes spawned during tests
node_name =
  Node.self()
  |> to_string()
  |> String.split("@")
  |> hd()
  |> String.to_charlist()

case :erl_epmd.port_please(node_name, ~c"127.0.0.1") do
  {:port, port, _version} -> :persistent_term.put(:expert_dist_port, port)
  _error -> :ok
end

Engine.Module.Loader.start_link(nil)
ExUnit.configure(timeout: :infinity, assert_receive_timeout: 1000)

ExUnit.start(exclude: [:skip])

if Version.match?(System.version(), ">= 1.15.0") do
  Logger.configure(level: :none)
else
  Logger.remove_backend(:console)
end
