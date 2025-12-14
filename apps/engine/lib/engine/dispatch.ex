defmodule Engine.Dispatch do
  @moduledoc """
  A global event dispatcher for expert.

  Dispatch allows two recipients of its messages, processes and modules. A process must register
  itself via a call to `register_listener`, while a process must implement the
  `Engine.Dispatch.Handler` behaviour and add the module to the @handlers module attribute.
  """

  alias Engine.Dispatch.Handlers
  alias Engine.Dispatch.PubSub
  alias Forge.Project

  @handlers [PubSub, Handlers.Indexing]

  # public API

  @doc """
  Registers a process that will receive messages sent directly to its pid.
  """

  def register_listener(listener_pid, message_types) when is_list(message_types) do
    :gen_event.call(__MODULE__, PubSub, PubSub.register_message(listener_pid, message_types))
  end

  def register_listener(listener_pid, event_or_all) do
    register_listener(listener_pid, List.wrap(event_or_all))
  end

  def add_handler(handler_module, init_args \\ []) do
    :gen_event.add_handler(__MODULE__, handler_module, init_args)
  end

  def registered?(pid) when is_pid(pid) do
    :gen_event.call(__MODULE__, PubSub, PubSub.registered_message(pid))
  end

  def registered?(name) when is_atom(name) do
    name in :gen_event.which_handlers(__MODULE__)
  end

  def broadcast(message) do
    :gen_event.notify(__MODULE__, message)
  end

  # GenServer callbacks

  def start_link(_opts) do
    case :gen_event.start_link(name()) do
      {:ok, pid} = success ->
        Enum.each(@handlers, &:gen_event.add_handler(pid, &1, []))
        success

      error ->
        error
    end
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, :dispatch},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  defp name, do: {:local, __MODULE__}

  def erpc_call(module, function, args) do
    :erpc.call(manager_node(), module, function, args, 1_000)
  end

  def erpc_cast(module, function, args) do
    :erpc.cast(manager_node(), module, function, args)
  end

  defp manager_node(), do: Engine.get_project() |> Project.manager_node_name()
end
