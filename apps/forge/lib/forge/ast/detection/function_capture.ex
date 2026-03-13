defmodule Forge.Ast.Detection.FunctionCapture do
  use Forge.Ast.Detection

  alias Forge.Ast.Analysis
  alias Forge.Ast.Detection
  alias Forge.Ast.Tokens
  alias Forge.Document.Position

  @impl Detection
  def detected?(%Analysis{} = analysis, %Position{} = position) do
    analysis.document
    |> Tokens.prefix_stream(position)
    |> Enum.reduce_while(false, fn
      {:paren, :")", _}, _ ->
        {:halt, false}

      {:operator, :&, _}, _ ->
        {:halt, true}

      {:int, _, _} = maybe_arity, _ ->
        {:cont, maybe_arity}

      {:operator, :/, _}, {:int, _, _} ->
        # if we encounter a trailing /<arity> in the prefix, the
        # function capture is complete, and we're not inside it
        {:halt, false}

      _, _ ->
        {:cont, false}
    end)
  end
end
