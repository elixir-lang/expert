defmodule Forge.Ast.Detection.ModuleAttribute do
  use Forge.Ast.Detection

  alias Forge.Ast.Analysis
  alias Forge.Ast.Detection
  alias Forge.Document.Position

  @impl Detection
  def detected?(%Analysis{} = analysis, %Position{} = position) do
    ancestor_is_attribute?(analysis, position)
  end

  def detected?(%Analysis{} = analysis, %Position{} = position, name) do
    ancestor_is_attribute?(analysis, position, name)
  end
end
