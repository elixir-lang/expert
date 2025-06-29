Code.require_file("../../mix_credo.exs")

Mix.Credo.config(
  excluded: ["lib/future/**/*.ex", "test/fixtures/**/*.ex", "test/fixtures/**/*.exs"]
)
