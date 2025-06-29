defmodule Expert.Provider.Handlers.DocumentSymbols do
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Forge.CodeIntelligence.Symbols
  alias Forge.Document
  alias GenLSP.Enumerations.SymbolKind
  alias GenLSP.Requests
  alias GenLSP.Structures

  def handle(%Requests.TextDocumentDocumentSymbol{} = request, %Configuration{} = config) do
    document = Document.Container.context_document(request.params, nil)

    symbols =
      config.project
      |> EngineApi.document_symbols(document)
      |> Enum.map(&to_response(&1, document))

    {:ok, symbols}
  end

  def to_response(%Symbols.Document{} = root, %Document{} = document) do
    children =
      case root.children do
        list when is_list(list) ->
          Enum.map(list, &to_response(&1, document))

        _ ->
          nil
      end

    %Structures.DocumentSymbol{
      children: children,
      detail: root.detail,
      kind: to_kind(root.type),
      name: root.name,
      range: root.range,
      selection_range: root.detail_range
    }
  end

  defp to_kind(:struct), do: SymbolKind.struct()
  defp to_kind(:module), do: SymbolKind.module()
  defp to_kind(:variable), do: SymbolKind.variable()
  defp to_kind({:function, _}), do: SymbolKind.function()
  defp to_kind({:protocol, _}), do: SymbolKind.module()
  defp to_kind(:module_attribute), do: SymbolKind.constant()
  defp to_kind(:ex_unit_test), do: SymbolKind.method()
  defp to_kind(:ex_unit_describe), do: SymbolKind.method()
  defp to_kind(:ex_unit_setup), do: SymbolKind.method()
  defp to_kind(:ex_unit_setup_all), do: SymbolKind.method()
  defp to_kind(:type), do: SymbolKind.type_parameter()
  defp to_kind(:spec), do: SymbolKind.interface()
  defp to_kind(:file), do: SymbolKind.file()
  defp to_kind(_), do: SymbolKind.string()
end
