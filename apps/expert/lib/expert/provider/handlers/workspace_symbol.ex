defmodule Expert.Provider.Handlers.WorkspaceSymbol do
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Forge.CodeIntelligence.Symbols
  alias GenLSP.Enumerations.SymbolKind
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  def handle(
        %Requests.WorkspaceSymbol{params: %Structures.WorkspaceSymbolParams{} = params},
        %Configuration{} = config
      ) do
    symbols =
      if String.length(params.query) > 1 do
        config.project
        |> EngineApi.workspace_symbols(params.query)
        |> tap(fn symbols -> Logger.info("syms #{inspect(Enum.take(symbols, 5))}") end)
        |> Enum.map(&to_response/1)
      else
        []
      end

    Logger.info("WorkspaceSymbol results: #{inspect(symbols, pretty: true)}")

    {:ok, symbols}
  end

  def to_response(%Symbols.Workspace{} = root) do
    %Structures.WorkspaceSymbol{
      kind: to_kind(root.type),
      location: to_location(root.link),
      name: root.name,
      container_name: root.container_name
    }
  end

  defp to_location(%Symbols.Workspace.Link{} = link) do
    %Structures.Location{uri: link.uri, range: link.detail_range}
  end

  defp to_kind(:struct), do: SymbolKind.struct()
  defp to_kind(:module), do: SymbolKind.module()
  defp to_kind({:protocol, _}), do: SymbolKind.module()
  defp to_kind({:xp_protocol, _}), do: SymbolKind.module()
  defp to_kind(:variable), do: SymbolKind.variable()
  defp to_kind({:function, _}), do: SymbolKind.function()
  defp to_kind(:module_attribute), do: SymbolKind.constant()
  defp to_kind(:ex_unit_test), do: SymbolKind.method()
  defp to_kind(:ex_unit_describe), do: SymbolKind.method()
  defp to_kind(:ex_unit_setup), do: SymbolKind.method()
  defp to_kind(:ex_unit_setup_all), do: SymbolKind.method()
  defp to_kind(:type), do: SymbolKind.type_parameter()
  defp to_kind(:spec), do: SymbolKind.interface()
  defp to_kind(:file), do: SymbolKind.file()
end
