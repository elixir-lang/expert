defmodule Lexical.RemoteControl.CodeAction.Handler do
  alias Lexical.Document
  alias Lexical.Document.Range
  alias Lexical.RemoteControl.CodeAction
  alias Lexical.RemoteControl.CodeAction.Diagnostic

  @callback actions(Document.t(), Range.t(), [Diagnostic.t()]) :: [CodeAction.t()]
  @callback kinds() :: [CodeAction.code_action_kind()]
  @callback trigger_kind() :: CodeAction.trigger_kind() | :all
end
