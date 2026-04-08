defmodule Expert.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Forge.Document
  alias Forge.LogFilter

  require Logger

  @impl true
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def start(_type, _args) do
    Forge.Identifier.start()

    :logger.update_primary_config(%{
      metadata: %{instance_id: Integer.to_string(System.os_time(:millisecond), 16)}
    })

    argv = Burrito.Util.Args.argv()

    # Handle engine subcommand first (before starting the LSP server)
    case argv do
      ["engine" | engine_args] ->
        engine_args
        |> Expert.Engine.run()
        |> System.halt()

      [subcommand | _] ->
        if not String.starts_with?(subcommand, "-") do
          IO.puts(:stderr, """
          Error: Unknown subcommand '#{subcommand}'

          Run 'expert --help' for usage information.
          """)

          System.halt(1)
        end

      _ ->
        :noop
    end

    {opts, _argv, _invalid} =
      OptionParser.parse(argv,
        strict: [
          version: :boolean,
          help: :boolean,
          stdio: :boolean,
          port: :integer,
          log_level: :string
        ]
      )

    help_text = """
    Expert v#{Expert.vsn()}

    The official language server for Elixir

      Home page: https://expert-lsp.org
    Source code: https://github.com/elixir-lang/expert

    expert [flags]
    expert engine <subcommand> [options]

    #{IO.ANSI.bright()}FLAGS#{IO.ANSI.reset()}

      --stdio             Use stdio as the transport mechanism
      --port <port>       Use TCP as the transport mechanism, with the given port
      --log-level <level> Set log level for log files (debug, info, warning, error). Default: debug
      --help              Show this help message
      --version           Show Expert version

    #{IO.ANSI.bright()}SUBCOMMANDS#{IO.ANSI.reset()}

      engine              Manage engine builds (use 'expert engine --help' for details)
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

    log_level = parse_log_level(opts[:log_level])
    Application.put_env(:expert, :log_level, log_level)

    buffer_opts =
      cond do
        opts[:stdio] ->
          :ok = Expert.Logging.ProjectLogFile.attach()
          :ok = mute_default_log_handler()
          Logger.info("Expert v#{Expert.vsn()} starting on stdio")
          apply_log_level(log_level)
          []

        is_integer(opts[:port]) ->
          :ok = Expert.Logging.ProjectLogFile.attach()
          :ok = mute_default_log_handler()
          IO.puts("Starting on port #{opts[:port]}")

          Logger.info("Expert v#{Expert.vsn()} starting on port #{opts[:port]}")

          apply_log_level(log_level)
          [communication: {GenLSP.Communication.TCP, [port: opts[:port]]}]

        true ->
          IO.puts(
            :stderr,
            "FATAL: A transport argument (--stdio|--port <port>) must be provided, expert won't initialize."
          )

          IO.puts(help_text)

          # Status code 2 is often used for invalid CLI argument
          System.halt(2)
      end

    ensure_epmd_module!()

    LogFilter.hook_into_logger()

    with {:error, reason} <- Expert.Logging.WindowLogHandler.attach() do
      Logger.warning("Failed to enable window/logMessage logger handler: #{inspect(reason)}")
    end

    children_spec = children(buffer: buffer_opts)
    opts = [strategy: :one_for_one, name: Expert.Supervisor]

    Supervisor.start_link(children_spec, opts)
  end

  def children(opts) do
    buffer_opts = Keyword.fetch!(opts, :buffer)

    [
      {Forge.NodePortMapper, []},
      document_store_child_spec(),
      {DynamicSupervisor, Expert.Project.DynamicSupervisor.options()},
      {DynamicSupervisor, name: Expert.DynamicSupervisor},
      {GenLSP.Assigns, [name: Expert.Assigns]},
      {Task.Supervisor, name: :expert_task_queue},
      {GenLSP.Buffer, [name: Expert.Buffer] ++ buffer_opts},
      {Expert.ActiveProjects, []},
      {Expert,
       name: Expert,
       buffer: Expert.Buffer,
       task_supervisor: :expert_task_queue,
       dynamic_supervisor: Expert.DynamicSupervisor,
       assigns: Expert.Assigns}
    ]
  end

  @doc false
  def document_store_child_spec do
    {Document.Store, derive: [analysis: &Forge.Ast.analyze/1]}
  end

  defp apply_log_level(log_level) do
    Logger.info("Log level set to #{log_level}")

    handler_name = Expert.Logging.ProjectLogFile.handler_name()
    :logger.update_handler_config(handler_name, :level, log_level)
    :logger.set_primary_config(:level, log_level)
  end

  defp parse_log_level(nil), do: :debug
  defp parse_log_level("debug"), do: :debug
  defp parse_log_level("info"), do: :info
  defp parse_log_level("warning"), do: :warning
  defp parse_log_level("error"), do: :error

  defp parse_log_level(other) do
    Logger.error("Invalid log level '#{other}'. Must be one of: debug, info, warning, error")
    System.halt(2)
  end

  defp mute_default_log_handler do
    case :logger.update_handler_config(:default, :level, :none) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
    end
  end

  def ensure_epmd_module! do
    epmd_module = to_charlist(Forge.EPMD)

    case :init.get_argument(:epmd_module) do
      {:ok, [[^epmd_module]]} ->
        :ok

      _ ->
        Application.put_env(:kernel, :epmd_module, Forge.EPMD, persistent: true)

        # Note: this is a private API
        if :net_kernel.epmd_module() != Forge.EPMD do
          raise("""
          you must set the environment variable ELIXIR_ERL_OPTIONS="-epmd_module #{Forge.EPMD}"
          """)
        end
    end
  end
end
