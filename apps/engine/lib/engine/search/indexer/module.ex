defmodule Engine.Search.Indexer.Module do
  alias Engine.Search.Indexer

  def index(module) do
    with true <- indexable?(module),
         {:ok, path, source} <- source_file_path(module) do
      Indexer.Source.index(path, source)
    else
      _ ->
        nil
    end
  end

  defp source_file_path(module) do
    with {:ok, file_path} <- Keyword.fetch(module.__info__(:compile), :source),
         {:ok, contents} <- File.read(file_path) do
      {:ok, file_path, contents}
    end
  end

  defp indexable?(Kernel.SpecialForms), do: false

  defp indexable?(module) do
    module_string = to_string(module)
    String.starts_with?(module_string, "Elixir.")
  end
end
