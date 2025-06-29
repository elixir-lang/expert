defmodule Forge.CodeIntelligence.Docs do
  alias Forge.CodeIntelligence.Docs.Entry

  defstruct [:module, :doc, functions_and_macros: [], callbacks: [], types: []]

  @type t :: %__MODULE__{
          module: module(),
          doc: Entry.content(),
          functions_and_macros: %{optional(atom()) => [Entry.t(:function | :macro)]},
          callbacks: %{optional(atom()) => [Entry.t(:callback)]},
          types: %{optional(atom()) => [Entry.t(:type)]}
        }
end
