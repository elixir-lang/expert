Mix.install([:benchee])

alias Forge.VM.Versions

Benchee.run(%{
  "versions" => fn ->
    Version.match?(Versions.current().elixir, ">=1.15.0")
  end,
  "current_versions_matches" => fn ->
    Versions.current_elixir_matches?(">=1.15.0")
  end
})
