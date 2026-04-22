defmodule Engine.CodeIntelligence.Structs do
  alias Engine.Module.Loader
  alias Engine.Search.Store
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  def for_project do
    for_project(Engine.get_project())
  end

  defp for_project(%Project{kind: :bare}) do
    {:ok, structs_from_index()}
  end

  defp for_project(%Project{kind: :mix}) do
    if Engine.Mix.loaded?() do
      {:ok, structs_from_index()}
    else
      Engine.Mix.in_project(fn _ -> structs_from_index() end)
    end
  end

  defp structs_from_index do
    case Store.exact(type: :struct, subtype: :definition) do
      {:ok, entries} ->
        for %Entry{subject: struct_module} <- entries,
            Loader.ensure_loaded?(struct_module) do
          struct_module
        end

      _ ->
        []
    end
  end
end
