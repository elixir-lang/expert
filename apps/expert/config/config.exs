import Config

config :snowflake,
  machine_id: 1,
  # First second of 2024
  epoch: 1_704_070_800_000

case dbg(System.get_env("EXPERT_RELEASE_MODE", "plain")) do
  "burrito" ->
    config :expert, arg_parser: {Burrito.Util.Args, :get_arguments, []}

  "plain" ->
    config :expert, arg_parser: {System, :argv, []}
end

import_config("#{config_env()}.exs")
