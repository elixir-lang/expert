import Config

if Code.ensure_loaded?(LoggerFileBackend) do
  log_directory = Path.join(File.cwd!(), ".expert")

  unless File.exists?(log_directory) do
    File.mkdir_p(log_directory)
  end

  log_file_name = Path.join(log_directory, "expert.log")

  config :logger,
    handle_sasl_reports: true,
    handle_otp_reports: true,
    backends: [{LoggerFileBackend, :general_log}]

  config :logger, :general_log,
    path: log_file_name,
    level: :debug
end

config :expert, :arg_parser, {System, :argv, []}
