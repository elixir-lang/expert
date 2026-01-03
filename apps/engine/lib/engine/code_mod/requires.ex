defmodule Engine.CodeMod.Requires do
  alias Engine.CodeMod.Directives
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Require
  alias Forge.Document.Position
  alias Forge.Document.Range

  @doc """
  Returns the position in the document where requires should be inserted
  """
  @spec insert_position(Analysis.t(), Position.t()) :: {Position.t(), String.t() | nil}
  def insert_position(%Analysis{} = analysis, %Position{} = cursor_position) do
    range = Range.new(cursor_position, cursor_position)
    current_requires = requires_in_scope(analysis, range)
    Directives.insert_position(analysis, range, current_requires)
  end

  @doc """
  Returns the requires that are in scope at the given range.
  """
  @spec in_scope(Analysis.t(), Range.t()) :: [Require.t()]
  def in_scope(%Analysis{} = analysis, %Range{} = range) do
    requires_in_scope(analysis, range)
  end

  @doc """
  Turns a list of requires into edits
  """
  @spec to_edits([Require.t()], Position.t(), trailer :: String.t() | nil) :: [
          Forge.Document.Edit.t()
        ]
  def to_edits(requires, position, trailer \\ nil)
  def to_edits([], _, _), do: []

  def to_edits(requires, %Position{} = insert_position, trailer) do
    Directives.to_edits(requires, insert_position, trailer,
      render: &render_require/1,
      sort_by: &sort_key/1,
      range: & &1.range
    )
  end

  defp requires_in_scope(%Analysis{} = analysis, %Range{} = range) do
    scope = Analysis.module_scope(analysis, range)

    scope.requires
    |> Enum.filter(&Range.contains?(scope.range, &1.range.start))
  end

  defp sort_key(%Require{} = require) do
    Enum.map(require.module, fn elem -> elem |> to_string() |> String.downcase() end)
  end

  defp render_require(%Require{} = require) do
    "require " <> join(require.module)
  end

  defp join(module) do
    Enum.join(module, ".")
  end
end
