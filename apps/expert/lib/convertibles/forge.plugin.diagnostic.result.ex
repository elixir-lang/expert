defimpl Forge.Protocol.Convertible, for: Forge.Plugin.V1.Diagnostic.Result do
  alias GenLSP.Structures
  alias GenLSP.Enumerations.DiagnosticSeverity
  alias Expert.Protocol.Conversions
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Math
  alias Forge.Plugin.V1.Diagnostic
  alias Forge.Text

  def to_lsp(%Diagnostic.Result{} = diagnostic) do
    with {:ok, lsp_range} <- lsp_range(diagnostic) do
      proto_diagnostic = %Structures.Diagnostic{
        message: diagnostic.message,
        range: lsp_range,
        severity: map_severity(diagnostic.severity),
        source: diagnostic.source
      }

      {:ok, proto_diagnostic}
    end
  end

  defp map_severity(:error), do: DiagnosticSeverity.error()
  defp map_severity(:warning), do: DiagnosticSeverity.warning()
  defp map_severity(:information), do: DiagnosticSeverity.information()
  defp map_severity(:hint), do: DiagnosticSeverity.hint()

  def to_native(%Diagnostic.Result{} = diagnostic, _) do
    {:ok, diagnostic}
  end

  defp lsp_range(%Diagnostic.Result{position: %Position{} = position}) do
    with {:ok, lsp_start_pos} <- Conversions.to_lsp(position) do
      range =
        %Structures.Range{
          start: lsp_start_pos,
          end: %Structures.Position{line: lsp_start_pos.line + 1, character: 0}
        }

      {:ok, range}
    end
  end

  defp lsp_range(%Diagnostic.Result{position: %Range{} = range}) do
    Conversions.to_lsp(range)
  end

  defp lsp_range(%Diagnostic.Result{uri: uri} = diagnostic) when is_binary(uri) do
    with {:ok, document} <- Document.Store.open_temporary(uri) do
      position_to_range(document, diagnostic.position)
    end
  end

  defp lsp_range(%Diagnostic.Result{}) do
    {:error, :no_uri}
  end

  defp position_to_range(%Document{} = document, {start_line, start_column, end_line, end_column}) do
    start_pos = Position.new(document, start_line, max(start_column, 1))
    end_pos = Position.new(document, end_line, max(end_column, 1))

    range = Range.new(start_pos, end_pos)
    Conversions.to_lsp(range)
  end

  defp position_to_range(%Document{} = document, {line_number, column}) do
    column = max(column, 1)

    document
    |> to_expert_range(line_number, column)
    |> Conversions.to_lsp()
  end

  defp position_to_range(document, line_number) when is_integer(line_number) do
    line_number = Math.clamp(line_number, 1, Document.size(document))

    with {:ok, line_text} <- Document.fetch_text_at(document, line_number) do
      column = Text.count_leading_spaces(line_text) + 1

      document
      |> to_expert_range(line_number, column)
      |> Conversions.to_lsp()
    end
  end

  defp position_to_range(document, nil) do
    position_to_range(document, 1)
  end

  defp to_expert_range(%Document{} = document, line_number, column) do
    line_number = Math.clamp(line_number, 1, Document.size(document) + 1)

    Range.new(
      Position.new(document, line_number, column),
      Position.new(document, line_number + 1, 1)
    )
  end
end
