defmodule Engine.CodeAction.Handlers.ReplaceWithUnderscore do
  alias Engine.CodeAction
  alias Forge.Ast
  alias Forge.CodeAction.Diagnostic
  alias Forge.Document
  alias Forge.Document.Changes
  alias Forge.Document.Range
  alias GenLSP.Enumerations.CodeActionKind
  alias Sourceror.Zipper

  @behaviour CodeAction.Handler

  @impl CodeAction.Handler
  def actions(%Document{} = doc, %Range{}, diagnostics) do
    Enum.reduce(diagnostics, [], fn %Diagnostic{} = diagnostic, acc ->
      with {:ok, variable_name, line_number} <- extract_variable_and_line(diagnostic),
           {:ok, changes} <- to_changes(doc, line_number, variable_name) do
        action =
          Forge.CodeAction.new(
            doc.uri,
            "Rename to _#{variable_name}",
            CodeActionKind.quick_fix(),
            changes
          )

        [action | acc]
      else
        _ ->
          acc
      end
    end)
  end

  @impl CodeAction.Handler
  def kinds do
    [CodeActionKind.quick_fix()]
  end

  @impl CodeAction.Handler
  def trigger_kind, do: :all

  @spec to_changes(Document.t(), non_neg_integer(), String.t() | atom) ::
          {:ok, Changes.t()} | :error
  defp to_changes(%Document{} = document, line_number, variable_name) do
    case apply_transform(document, line_number, variable_name) do
      {:ok, edits} ->
        {:ok, Changes.new(document, edits)}

      error ->
        error
    end
  end

  defp apply_transform(document, line_number, unused_variable_name) do
    underscored_variable_name = :"_#{unused_variable_name}"

    result =
      Ast.traverse_line(document, line_number, [], fn
        %Zipper{node: {^unused_variable_name, _meta, nil} = node} = zipper, patches ->
          patch = Sourceror.Patch.rename_identifier(node, underscored_variable_name)
          {zipper, [patch | patches]}

        zipper, acc ->
          {zipper, acc}
      end)

    with {:ok, _, patches} <- result do
      Ast.patches_to_edits(document, patches)
    end
  end

  defp extract_variable_and_line(%Diagnostic{} = diagnostic) do
    with {:ok, variable_name} <- extract_variable_name(diagnostic.message),
         {:ok, line} <- extract_line(diagnostic) do
      {:ok, variable_name, line}
    end
  end

  @variable_re ~r/variable "([^"]+)" is unused/
  defp extract_variable_name(message) do
    case Regex.scan(@variable_re, message) do
      [[_, variable_name]] ->
        {:ok, String.to_atom(variable_name)}

      _ ->
        {:error, {:no_variable, message}}
    end
  end

  defp extract_line(%Diagnostic{} = diagnostic) do
    {:ok, diagnostic.range.start.line}
  end
end
