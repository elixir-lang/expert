import Config

parser =
  case System.get_env("EXPERT_PARSER") do
    "elixir" -> :elixir
    _ -> :spitfire
  end

config :forge, :parser, parser

config :snowflake,
  machine_id: 1,
  # First second of 2024
  epoch: 1_704_070_800_000
