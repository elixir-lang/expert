import Config

parser =
  case System.get_env("EXPERT_PARSER") do
    "elixir" -> :elixir
    _ -> :spitfire
  end

config :forge, :parser, parser
