defmodule Engine.CodeAction.Handlers.Require do
  alias Engine.CodeAction
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Require
  alias Forge.Document
  alias Forge.Document.Changes
  alias GenLSP.Enumerations.CodeActionKind

  @behaviour CodeAction.Handler

  @impl CodeAction.Handler
  def actions(document, range, diagnostics) do
    with {:ok, _doc, %Analysis{valid?: true} = analysis} <-
           Document.Store.fetch(document.uri, :analysis),
         diagnostic when not is_nil(diagnostic) <-
           Enum.find(diagnostics, &(&1.message =~ "require")),
         {:ok, module_string} <- get_module(diagnostic.message) do
      current_requires = Engine.CodeMod.Requires.in_scope(analysis, range)

      {insert_position, trailer} =
        Engine.CodeMod.Requires.insert_position(analysis, range.start)

      module_atom = Module.concat([module_string])
      {:elixir, segments} = Forge.Ast.Module.safe_split(module_atom, as: :atoms)
      require_to_add = %Require{module: segments, as: List.last(segments)}

      edits =
        Engine.CodeMod.Requires.to_edits(
          [require_to_add | current_requires],
          insert_position,
          trailer
        )

      changes = Changes.new(analysis.document, edits)

      [
        Forge.CodeAction.new(
          analysis.document.uri,
          "Add require for #{module_string}",
          CodeActionKind.quick_fix(),
          changes
        )
      ]
    else
      _ ->
        []
    end
  end

  @impl CodeAction.Handler
  def kinds do
    [CodeActionKind.quick_fix()]
  end

  @impl CodeAction.Handler
  def trigger_kind, do: :all

  def get_module(message) do
    patterns =
      [
        ~r/require\s+([A-Za-z0-9_.!?]+)\s+before/,
        ~r/require\s+([A-Za-z0-9_.!?]+)\s+if you intend/
      ]

    result =
      Enum.find_value(patterns, fn pattern ->
        case Regex.run(pattern, message) do
          [_, module] -> module
          _ -> nil
        end
      end)

    case result do
      nil -> {:error, "require not found in diagnostic message"}
      module -> {:ok, module}
    end
  end
end
