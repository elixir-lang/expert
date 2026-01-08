defmodule Engine.CodeAction do
  alias Engine.CodeAction.Handlers
  alias Forge.CodeAction.Diagnostic
  alias Forge.Document
  alias Forge.Document.Range

  @handlers [
    Handlers.ReplaceRemoteFunction,
    Handlers.ReplaceWithUnderscore,
    Handlers.OrganizeAliases,
    Handlers.AddAlias,
    Handlers.Require,
    Handlers.RemoveUnusedAlias,
    Handlers.Refactorex,
    Handlers.CreateUndefinedFunction
  ]

  @spec for_range(
          Document.t(),
          Range.t(),
          [Diagnostic.t()],
          [Forge.CodeAction.code_action_kind()] | :all,
          Forge.CodeAction.trigger_kind()
        ) :: [Forge.CodeAction.t()]
  def for_range(%Document{} = doc, %Range{} = range, diagnostics, kinds, trigger_kind) do
    Enum.flat_map(@handlers, fn handler ->
      if handle_kinds?(handler, kinds) and handle_trigger_kind?(handler, trigger_kind) do
        handler.actions(doc, range, diagnostics)
      else
        []
      end
    end)
  end

  defp handle_kinds?(_handler, :all), do: true
  defp handle_kinds?(handler, kinds), do: kinds -- handler.kinds() != kinds

  defp handle_trigger_kind?(handler, trigger_kind),
    do: handler.trigger_kind() in [trigger_kind, :all]
end
