import Config

config :logger, level: :none

config :forge,
  document_store_clustering: :global

config :engine,
  edit_window_millis: 10,
  modules_cache_expiry: {50, :millisecond},
  search_store_quiescent_period_ms: 10

config :stream_data, initial_size: 50
