defmodule Forge.CodeAction do
  alias Forge.Document.Changes

  require Logger

  defstruct [:title, :kind, :changes, :uri]

  @type code_action_kind :: GenLSP.Enumerations.CodeActionKind.t()

  @type trigger_kind :: GenLSP.Enumerations.CodeActionTriggerKind.t()

  @type t :: %__MODULE__{
          title: String.t(),
          kind: code_action_kind,
          changes: Changes.t(),
          uri: Forge.uri()
        }

  @spec new(Forge.uri(), String.t(), code_action_kind(), Changes.t()) :: t()
  def new(uri, title, kind, changes) do
    %__MODULE__{uri: uri, title: title, changes: changes, kind: kind}
  end
end
