defmodule Expert.Stdio.User do
  @moduledoc """
  An alternative OTP's `user_drv` that allows Expert to isolate `:stdio` to GenLSP's Buffer.

  Installed with the `-user` emulator flag in `vm.args.eex` which makes `user_sup` call `start/0`
  rather than Erlang's `user_drv`. Ordinary `io_request`s are forwarded verbatim to `:standard_error`,
  so anything written through `IO`, `:io`, `Logger` or a dependency lands on stderr. Protocol bytes
  travel over a private message instead, which is what keeps a stray `IO.inspect/2` off the LSP channel.
  """

  use GenServer

  alias Expert.Stdio.User.State

  ## API

  @doc """
  Claims the exclusive right to write protocol bytes. Called by the transport.
  """
  @spec claim() :: :ok | {:error, :already_claimed}
  def claim, do: GenServer.call(:user, :claim)

  @doc """
  Routes stdin to the calling process as `{:lsp_stdin, bytes}` and `:lsp_stdin_eof`.
  """
  @spec subscribe() :: :ok | {:error, :already_subscribed}
  def subscribe, do: GenServer.call(:user, :subscribe)

  @doc """
  Writes an already framed packet to stdout, the only path to file descriptor 1.
  """
  @spec write(iodata()) :: :ok | {:error, term()}
  def write(packet), do: GenServer.call(:user, {:write, packet}, :infinity)

  ## Init

  @doc """
  Entry point for the `-user` boot flag, invoked by `user_sup` rather than directly.
  """
  @spec start() :: pid()
  def start do
    if ~c"--stdio" in :init.get_plain_arguments() do
      {:ok, pid} = GenServer.start_link(__MODULE__, [], name: :user)
      pid
    else
      :user_drv.start()
    end
  end

  @impl GenServer
  def init(_args) do
    Process.flag(:trap_exit, true)
    stderr = Process.whereis(:standard_error) || exit(:standard_error_not_started)

    {:ok, State.new(stderr, Port.open({:fd, 0, 1}, [:binary, :stream, :eof]))}
  end

  ## Callbacks

  @impl GenServer
  def handle_call({:write, packet}, {pid, _tag}, %State{owner: pid} = state) do
    {:reply, write_packet(state.port, packet), state}
  end

  def handle_call({:write, _packet}, _from, %State{} = state) do
    {:reply, {:error, :not_owner}, state}
  end

  def handle_call(:claim, {pid, _tag}, %State{owner: nil} = state) do
    Process.monitor(pid)

    {:reply, :ok, %State{state | owner: pid}}
  end

  def handle_call(:claim, {pid, _tag}, %State{owner: pid} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:claim, _from, %State{} = state) do
    {:reply, {:error, :already_claimed}, state}
  end

  # stdin starts flowing at kernel boot, long before the transport is supervised, so anything
  # that arrived in the meantime is replayed here. Dropping it would lose an `initialize`
  # request from a client that writes immediately.
  def handle_call(:subscribe, {pid, _tag}, %State{reader: nil} = state) do
    Process.monitor(pid)

    if state.pending != <<>>, do: send(pid, {:lsp_stdin, state.pending})
    if state.eof?, do: send(pid, :lsp_stdin_eof)

    {:reply, :ok, %State{state | reader: pid, pending: <<>>}}
  end

  def handle_call(:subscribe, {pid, _tag}, %State{reader: pid} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:subscribe, _from, %State{} = state) do
    {:reply, {:error, :already_subscribed}, state}
  end

  @impl GenServer
  # `:standard_error` only accepts the encoding, onlcr and log options and answers
  # `{:error, :enotsup}` to anything else, including the `[binary: true]` Elixir sets on
  # standard_io while booting. Relaying that would kill the VM before Elixir starts.
  def handle_info({:io_request, from, reply_as, {:setopts, _opts}}, %State{} = state) do
    io_reply(from, reply_as, :ok)

    {:noreply, state}
  end

  def handle_info({:io_request, from, reply_as, :getopts}, %State{} = state) do
    io_reply(from, reply_as, binary: true, encoding: :latin1)

    {:noreply, state}
  end

  # Nothing should be reading from `:user` as stdin belongs to the LSP transport.
  def handle_info({:io_request, from, reply_as, request}, %State{} = state)
      when elem(request, 0) in [:get_chars, :get_line, :get_until, :get_password] do
    io_reply(from, reply_as, :eof)

    {:noreply, state}
  end

  # Forwarding the tuple unchanged matters: `:standard_error` replies straight to the original
  # caller, which keeps `IO.write/2` synchronous for it.
  def handle_info({:io_request, from, _reply_as, _request} = request, %State{} = state)
      when is_pid(from) do
    send(state.stderr, request)

    {:noreply, state}
  end

  def handle_info({port, {:data, bytes}}, %State{port: port, reader: reader} = state)
      when is_pid(reader) do
    send(reader, {:lsp_stdin, bytes})

    {:noreply, state}
  end

  def handle_info({port, {:data, bytes}}, %State{port: port} = state) do
    {:noreply, %State{state | pending: state.pending <> bytes}}
  end

  def handle_info({port, :eof}, %State{port: port} = state) do
    if state.reader, do: send(state.reader, :lsp_stdin_eof)

    {:noreply, %State{state | eof?: true}}
  end

  # Let a restarted transport claim the channel again. The port outlives it.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %State{owner: pid} = state) do
    {:noreply, %State{state | owner: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %State{reader: pid} = state) do
    {:noreply, %State{state | reader: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %State{} = state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, port, reason}, %State{port: port} = state) do
    {:stop, {:stdio_port_terminated, reason}, state}
  end

  # As `:user` this is the group leader of last resort, so unrecognised messages are routine.
  def handle_info(_message, %State{} = state), do: {:noreply, state}

  defp io_reply(from, reply_as, reply), do: send(from, {:io_reply, reply_as, reply})

  defp write_packet(port, packet) do
    true = Port.command(port, packet)

    :ok
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
