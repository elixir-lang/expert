defmodule Expert.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  alias Forge.Document
  alias Forge.LogFilter

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    {m, f, a} = Application.get_env(:expert, :arg_parser)

    argv = apply(m, f, a)

    {opts, _, _invalid} =
      OptionParser.parse(argv,
        strict: [port: :integer]
      )

    buffer_opts =
      case opts[:port] do
        port when is_integer(port) ->
          [communication: {GenLSP.Communication.TCP, [port: port]}]

        _ ->
          []
      end

    children = [
      document_store_child_spec(),
      {DynamicSupervisor, Expert.Project.DynamicSupervisor.options()},
      {DynamicSupervisor, name: Expert.DynamicSupervisor},
      {GenLSP.Assigns, [name: Expert.Assigns]},
      {Task.Supervisor, name: :expert_task_queue},
      {GenLSP.Buffer, [name: Expert.Buffer] ++ buffer_opts},
      {Expert,
       name: Expert,
       buffer: Expert.Buffer,
       task_supervisor: :expert_task_queue,
       dynamic_supervisor: Expert.DynamicSupervisor,
       assigns: Expert.Assigns}
    ]

    LogFilter.hook_into_logger()

    opts = [strategy: :one_for_one, name: Expert.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  def document_store_child_spec do
    {Document.Store, derive: [analysis: &Forge.Ast.analyze/1]}
  end
end
