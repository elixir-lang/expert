defmodule Engine.Dispatch.Handlers.Indexing do
  use Engine.Dispatch.Handler, [file_compile_requested(), filesystem_event()]

  import Forge.EngineApi.Messages

  alias Engine.Commands
  alias Engine.Search
  alias Forge.Document

  require Logger

  def on_event(file_compile_requested(uri: uri), state) do
    reindex(uri)
    {:ok, state}
  end

  def on_event(filesystem_event(uri: uri, event_type: :deleted), state) do
    delete_path(uri)
    {:ok, state}
  end

  def on_event(filesystem_event(), state) do
    {:ok, state}
  end

  defp reindex(uri) do
    Commands.Reindex.uri(uri)
  end

  def delete_path(uri) do
    uri
    |> Document.Path.ensure_path()
    |> Search.Store.clear()
  end
end
