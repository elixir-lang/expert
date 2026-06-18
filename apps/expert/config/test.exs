import Config

# Without this option, ExUnit would randomly not terminate or tests would behave
# erratically.
config :gen_lsp, :exit_on_end, false

config :engine, edit_window_millis: 10
