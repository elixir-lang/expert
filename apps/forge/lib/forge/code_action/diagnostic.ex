defmodule Forge.CodeAction.Diagnostic do
  alias Forge.Document.Range

  defstruct [:range, :message, :source]
  @type message :: String.t()
  @type source :: String.t()
  @type t :: %__MODULE__{
          range: Range.t(),
          message: message() | nil,
          source: source() | nil
        }

  @spec new(Range.t(), message(), source() | nil) :: t
  def new(%Range{} = range, message, source) do
    %__MODULE__{range: range, message: message, source: source}
  end
end
