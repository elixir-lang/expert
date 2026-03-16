defmodule Forge.Ast.Detection.StructFieldKey do
  use Forge.Ast.Detection

  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Detection
  alias Forge.Document.Position

  @impl Detection
  def detected?(%Analysis{} = analysis, %Position{} = position) do
    cursor_path = Ast.cursor_path(analysis, position)

    match?(
      # in the key position, the cursor will always be followed by the
      # map node because, in any other case, there will minimally be a
      # 2-element key-value tuple containing the cursor
      [{:__cursor__, _, _}, {:%{}, _, _}, {:%, _, _} | _],
      cursor_path
    )
  end
end
