import Config

config :snowflake,
  machine_id: 1,
  # First second of 2024
  epoch: 1_704_070_800_000

config :forge,
  # NOTE(dorgan): In dev/prod we use Swarm for distribution,
  # mainly to avoid using EPMD. This works well in practice,
  # but in tests Swarm becomes incredibly noisy and causes
  # lots of timing issues and introduces lots of flakiness.
  # So in tests we use :global instead.
  document_store_clustering: :global
