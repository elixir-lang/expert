defmodule Engine.CodeMod.Aliases do
  alias Engine.CodeMod.Directives
  alias Forge.Ast.Analysis
  alias Forge.Ast.Analysis.Alias
  alias Forge.Ast.Analysis.Scope
  alias Forge.Document.Edit
  alias Forge.Document.Position
  alias Forge.Document.Range

  @doc """
  Returns the aliases that are in scope at the given range.
  """
  @spec in_scope(Analysis.t(), Range.t()) :: [Alias.t()]
  def in_scope(%Analysis{} = analysis, %Range{} = range) do
    analysis
    |> Analysis.module_scope(range)
    |> aliases_in_scope()
  end

  @doc """
  Sorts the given aliases according to our rules
  """
  @spec sort(Enumerable.t(Alias.t())) :: [Alias.t()]
  def sort(aliases) do
    Enum.sort_by(aliases, fn %Alias{} = scope_alias ->
      Enum.map(scope_alias.module, fn elem -> elem |> to_string() |> String.downcase() end)
    end)
  end

  @doc """
  Returns the position in the document where aliases should be inserted
  Since a document can have multiple module definitions, the cursor position is used to
  determine the initial starting point.

  This function also returns a string that should be appended to the end of the
  edits that are performed.
  """
  @spec insert_position(Analysis.t(), Position.t()) :: {Position.t(), String.t() | nil}
  def insert_position(%Analysis{} = analysis, %Position{} = cursor_position) do
    range = Range.new(cursor_position, cursor_position)
    current_aliases = in_scope(analysis, range)
    Directives.insert_position(analysis, range, current_aliases)
  end

  @doc """
  Turns a list of aliases into aliases into edits
  """
  @spec to_edits([Alias.t()], Position.t(), trailer :: String.t() | nil) :: [Edit.t()]

  def to_edits(aliases, position, trailer \\ nil)
  def to_edits([], _, _), do: []

  def to_edits(aliases, %Position{} = insert_position, trailer) do
    Directives.to_edits(aliases, insert_position, trailer,
      render: &render_alias/1,
      sort_by: &sort_key/1,
      range: & &1.range
    )
  end

  defp aliases_in_scope(%Scope{} = scope) do
    scope.aliases
    |> Enum.filter(fn %Alias{} = scope_alias ->
      scope_alias.explicit? and Range.contains?(scope.range, scope_alias.range.start)
    end)
    |> sort()
  end

  defp join(module) do
    Enum.join(module, ".")
  end

  defp sort_key(%Alias{} = scope_alias) do
    Enum.map(scope_alias.module, fn elem -> elem |> to_string() |> String.downcase() end)
  end

  defp render_alias(%Alias{} = a) do
    if List.last(a.module) == a.as do
      "alias #{join(a.module)}"
    else
      "alias #{join(a.module)}, as: #{join(List.wrap(a.as))}"
    end
  end
end
