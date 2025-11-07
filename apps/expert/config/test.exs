import Config

config :forge,
  # Expert does need proper clustering even in tests,
  # since a lot of tests actually rely on actual nodes
  # being started and needing proper distribution.
  document_store_clustering: :swarm
