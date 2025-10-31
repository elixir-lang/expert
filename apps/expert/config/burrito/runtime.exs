import Config

Code.require_file("../runtime/common.exs")

config :expert, :arg_parser, {Burrito.Util.Args, :get_arguments, []}
