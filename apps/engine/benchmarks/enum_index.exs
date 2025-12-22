Mix.install([:benchee])

alias Engine.Search.Indexer

path =
  [__DIR__, "**", "enum.ex"]
  |> Path.join()
  |> Path.wildcard()
  |> List.first()

{:ok, source} = File.read(path)

Benchee.run(
  %{
    "indexing source code" => fn -> Indexer.Source.index(path, source) end
  },
  profile_after: true
)
