defmodule Engine.Dispatch.Handlers.Indexing do
  use Engine.Dispatch.Handler, [file_compile_requested(), file_compiled(), filesystem_event()]

  import Forge.EngineApi.Messages

  alias Engine.Commands
  alias Engine.ManagerApi
  alias Forge.Document

  def on_event(file_compile_requested(uri: uri), state) do
    if script_source?(uri), do: Commands.Reindex.uri(uri)

    {:ok, state}
  end

  def on_event(file_compiled(), state) do
    {:ok, state}
  end

  def on_event(filesystem_event(uri: uri, event_type: :deleted), state) do
    delete_path(uri)
    {:ok, state}
  end

  def on_event(filesystem_event(), state) do
    {:ok, state}
  end

  defp script_source?(uri) do
    Path.extname(Document.Path.ensure_path(uri)) == ".exs"
  end

  def delete_path(uri) do
    path = Document.Path.ensure_path(uri)
    project = Engine.get_project()
    ManagerApi.search_store_clear(project, path)
  end
end
