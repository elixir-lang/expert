defmodule Forge.Ast.Detection.Bitstring do
  use Forge.Ast.Detection

  alias Forge.Ast.Analysis
  alias Forge.Ast.Detection
  alias Forge.Ast.Tokens
  alias Forge.Document
  alias Forge.Document.Position

  @impl Detection
  def detected?(%Analysis{} = analysis, %Position{} = position) do
    document = analysis.document
    Document.fragment(document, Position.new(document, position.line, 1), position)

    document
    |> Tokens.prefix_stream(position)
    |> Enum.reduce_while(
      false,
      fn
        {:operator, :">>", _}, _ -> {:halt, false}
        {:operator, :"<<", _}, _ -> {:halt, true}
        _, _ -> {:cont, false}
      end
    )
  end
end
