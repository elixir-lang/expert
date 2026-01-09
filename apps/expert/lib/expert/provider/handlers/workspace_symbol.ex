defmodule Expert.Provider.Handlers.WorkspaceSymbol do
  alias Expert.ActiveProjects
  alias Expert.Configuration
  alias Expert.Configuration.WorkspaceSymbols
  alias Expert.EngineApi
  alias Forge.CodeIntelligence.Symbols
  alias Forge.Project
  alias GenLSP.Enumerations.SymbolKind
  alias GenLSP.Requests
  alias GenLSP.Structures

  def handle(
        %Requests.WorkspaceSymbol{params: %Structures.WorkspaceSymbolParams{} = params} = request,
        %Configuration{}
      ) do
    config = Configuration.get()
    projects = ActiveProjects.projects()

    symbols =
      if should_return_symbols?(params.query, config) do
        Enum.flat_map(projects, &gather_symbols(&1, request))
      else
        []
      end

    {:ok, symbols}
  end

  defp should_return_symbols?(query, %Configuration{
         workspace_symbols: %WorkspaceSymbols{min_query_length: min_length}
       }) do
    String.length(query) >= min_length
  end

  defp gather_symbols(
         %Project{} = project,
         %Requests.WorkspaceSymbol{
           params: %Structures.WorkspaceSymbolParams{} = params
         }
       ) do
    project
    |> EngineApi.workspace_symbols(params.query)
    |> Enum.map(&to_lsp_symbol/1)
  end

  def to_lsp_symbol(%Symbols.Workspace{} = root) do
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
