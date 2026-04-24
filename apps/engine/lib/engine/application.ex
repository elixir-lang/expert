defmodule Engine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Forge.Identifier.start()

    children =
      if Engine.project_node?() do
        [
          Engine.ApplicationCache,
          Engine.Api.Proxy,
          Engine.Commands.Reindex,
          Engine.Module.Loader,
          Engine.Dispatch,
          Engine.ModuleMappings,
          Engine.Build,
          Engine.ModuleStore,
          Engine.Build.CaptureServer,
          Engine.Plugin.Runner.Supervisor,
          Engine.Plugin.Runner.Coordinator,
          Engine.Search.Store.Backends.Ets,
          {Engine.Search.Store,
           [
             &Engine.Search.Indexer.create_index/1,
             &Engine.Search.Indexer.update_index/2
           ]}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Engine.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
