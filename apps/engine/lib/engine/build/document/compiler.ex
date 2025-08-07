defmodule Engine.Build.Document.Compiler do
  @moduledoc """
  A behaviour for document-level compilers
  """
  alias Forge.Document
  alias Forge.Plugin.V1.Diagnostic

  @type compile_response :: {:ok, [Diagnostic.Result.t()]} | {:error, [Diagnostic.Result.t()]}

  @doc """
  Compiles a document
  Compiles a document, returning an error tuple if the document won't compile,
  or an ok tuple if it does. In either case, it will also return a list of warnings or errors
  """
  @callback compile(Document.t()) :: compile_response()

  @doc """
  Returns true if the document can be compiled by the given compiler.
  """
  @callback recognizes?(Document.t()) :: boolean()

  @doc """
  Returns true if the compiler is enabled.
  """
  @callback enabled?() :: boolean
end
