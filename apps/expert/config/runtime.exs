import Config

config :logger,
  handle_sasl_reports: true,
  handle_otp_reports: true

config :logger, :default_handler, level: :none
