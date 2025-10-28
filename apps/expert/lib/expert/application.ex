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
    {opts, _argv, _invalid} =
      OptionParser.parse(Burrito.Util.Args.argv(),
        strict: [version: :boolean, help: :boolean, stdio: :boolean, port: :integer]
      )

    help_text = """
    Expert v#{Expert.vsn()}

    The official language server for Elixir

      Home page: https://expert-lsp.org
    Source code: https://github.com/elixir-lang/expert

    expert [flags]

    #{IO.ANSI.bright()}FLAGS#{IO.ANSI.reset()}

      --stdio             Use stdio as the transport mechanism
      --port <port>       Use TCP as the transport mechanism, with the given port
      --help              Show this help message
      --version           Show Expert version
    """

    cond do
      opts[:help] ->
        IO.puts(help_text)

        System.halt(0)

      opts[:version] ->
        IO.puts("#{Expert.vsn()}")
        System.halt(0)

      true ->
        :noop
    end

    buffer_opts =
      cond do
        opts[:stdio] ->
          []

        is_integer(opts[:port]) ->
          IO.puts("Starting on port #{opts[:port]}")
          [communication: {GenLSP.Communication.TCP, [port: opts[:port]]}]

        true ->
          IO.puts(help_text)

          System.halt(1)
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
