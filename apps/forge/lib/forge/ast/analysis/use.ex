defmodule Forge.Ast.Analysis.Use do
  alias Forge.Ast
  alias Forge.Document

  defstruct [:module, :range, :opts]

  def new(%Document{} = document, ast, module, opts) do
    range = Ast.Range.get(ast, document)
    %__MODULE__{range: range, module: module, opts: opts}
  end
end
