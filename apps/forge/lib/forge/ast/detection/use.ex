defmodule Forge.Ast.Detection.Use do
  use Forge.Ast.Detection

  alias Forge.Ast.Analysis
  alias Forge.Ast.Detection
  alias Forge.Ast.Detection.Directive
  alias Forge.Document.Position

  @impl Detection
  def detected?(%Analysis{} = analysis, %Position{} = position) do
    Directive.detected?(analysis, position, ~c"use")
  end
end
