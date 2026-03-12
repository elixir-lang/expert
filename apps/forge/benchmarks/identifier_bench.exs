Forge.Identifier.start()

Benchee.run(
  %{
    "Forge.identifier" => fn ->
      Forge.Identifier.next_global!()
    end
  },
  profile_after: true
)
