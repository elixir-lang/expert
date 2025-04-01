defmodule Lexical.RemoteControl.CodeAction do
  alias Lexical.Document
  alias Lexical.Document.Changes
  alias Lexical.Document.Range
  alias Lexical.RemoteControl.CodeAction.Diagnostic
  alias Lexical.RemoteControl.CodeAction.Handlers

  defstruct [:title, :kind, :changes, :uri]

  @type code_action_kind ::
          :empty
          | :quick_fix
          | :refactor
          | :refactor_extract
          | :refactor_inline
          | :refactor_rewrite
          | :source
          | :source_organize_imports
          | :source_fix_all

  @type trigger_kind :: :invoked | :automatic

  @type t :: %__MODULE__{
          title: String.t(),
          kind: code_action_kind,
          changes: Changes.t(),
          uri: Lexical.uri()
        }

  @handlers [
    Handlers.ReplaceRemoteFunction,
    Handlers.ReplaceWithUnderscore,
    Handlers.OrganizeAliases,
    Handlers.AddAlias,
    Handlers.RemoveUnusedAlias,
    Handlers.Refactorex
  ]

  @spec new(Lexical.uri(), String.t(), code_action_kind(), Changes.t()) :: t()
  def new(uri, title, kind, changes) do
    %__MODULE__{uri: uri, title: title, changes: changes, kind: kind}
  end

  @spec for_range(
          Document.t(),
          Range.t(),
          [Diagnostic.t()],
          [code_action_kind] | :all,
          trigger_kind
        ) :: [t()]
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
