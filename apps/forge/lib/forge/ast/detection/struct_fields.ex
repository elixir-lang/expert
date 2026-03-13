defmodule Forge.Ast.Detection.StructFields do
  use Forge.Ast.Detection

  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Detection
  alias Forge.Document.Position

  @impl Detection
  def detected?(%Analysis{} = analysis, %Position{} = position) do
    analysis.document
    |> Ast.cursor_path(position)
    |> Enum.any?(&match?({:%, _, _}, &1))
  end
end
