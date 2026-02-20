import Config

log_directory = Path.join(File.cwd!(), ".expert")

unless File.exists?(log_directory) do
  File.mkdir_p(log_directory)
end

log_file_name = Path.join(log_directory, "expert.log")

config :logger,
  handle_sasl_reports: true,
  handle_otp_reports: true

config :logger, :default_handler,
  level: :debug,
  config: [
    file: String.to_charlist(log_file_name),
    max_no_bytes: :infinity,
    max_no_files: 0
  ]
