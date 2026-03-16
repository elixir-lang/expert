defmodule Forge.Ast.Detection.StructReference do
  use Forge.Ast.Detection

  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Detection
  alias Forge.Ast.Tokens
  alias Forge.Document.Position

  @impl Detection
  def detected?(%Analysis{} = analysis, %Position{} = position) do
    case Ast.cursor_context(analysis, position) do
      {:ok, {:struct, []}} ->
        false

      {:ok, {:struct, _}} ->
        true

      {:ok, {:local_or_var, [?_ | _rest] = possible_module_struct}} ->
        # a reference to `%__MODULE`, often in a function head, as in
        # def foo(%__)

        starts_with_percent? =
          analysis.document
          |> Tokens.prefix_stream(position)
          |> Enum.take(2)
          |> Enum.any?(fn
            {:percent, :%, _} -> true
            _ -> false
          end)

        starts_with_percent? and possible_dunder_module(possible_module_struct) and
          (ancestor_is_def?(analysis, position) or ancestor_is_type?(analysis, position))

      _ ->
        false
    end
  end

  def possible_dunder_module(charlist) do
    String.starts_with?("__MODULE__", to_string(charlist))
  end
end
