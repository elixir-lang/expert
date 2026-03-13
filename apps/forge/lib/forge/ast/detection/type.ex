defmodule Forge.Ast.Detection.Type do
  use Forge.Ast.Detection

  alias Forge.Ast.Analysis
  alias Forge.Ast.Detection
  alias Forge.Document.Position

  @impl Detection
  def detected?(%Analysis{} = analysis, %Position{} = position) do
    ancestor_is_type?(analysis, position)
  end
end
