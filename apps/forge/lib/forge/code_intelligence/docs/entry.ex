defmodule Forge.CodeIntelligence.Docs.Entry do
  @moduledoc """
  A documentation entry for a named entity within a module.
  """

  defstruct [
    :module,
    :kind,
    :name,
    :arity,
    :signature,
    :doc,
    :metadata,
    defs: []
  ]

  @type t(kind) :: %__MODULE__{
          module: module(),
          kind: kind,
          name: atom(),
          arity: arity(),
          signature: [String.t()],
          doc: content(),
          metadata: metadata(),
          defs: [String.t()]
        }

  @type content :: String.t() | :none | :hidden

  @type metadata :: %{
          optional(:defaults) => pos_integer(),
          optional(:since) => String.t(),
          optional(:guard) => boolean(),
          optional(:opaque) => boolean(),
          optional(:deprecated) => boolean()
        }

  @known_metadata [:defaults, :since, :guard, :opaque, :deprecated]

  @doc false
  def from_docs_v1(module, {{kind, name, arity}, _anno, signature, doc, meta}) do
    %__MODULE__{
      module: module,
      kind: kind,
      name: name,
      arity: arity,
      signature: signature,
      doc: parse_doc(doc),
      metadata: Map.take(meta, @known_metadata)
    }
  end

  @doc false
  def parse_doc(%{"en" => doc}), do: doc
  def parse_doc(atom) when atom in [:none, :hidden], do: atom
end
