# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Forge.Refactor.Variable.UnderscoreNotUsed do
  use Forge.Refactor,
    title: "Underscore variables not used",
    kind: "quickfix",
    works_on: :line

  alias Forge.Refactor.Dataflow

  def can_refactor?(%{node: node}, line) do
    node
    |> Dataflow.group_variables_semantically()
    |> Enum.any?(fn
      {{name, _, _} = declaration, []} ->
        AST.starts_at?(declaration, line) and
          not String.starts_with?("#{name}", "_")

      {_declaration, _usages} ->
        false
    end)
    |> if(do: true, else: :skip)
  end

  def refactor(%{node: node} = zipper, line) do
    node
    |> Dataflow.group_variables_semantically()
    |> Stream.filter(&same_line_and_no_usages?(&1, line))
    |> Enum.reduce(zipper, fn
      {declaration, []}, zipper ->
        zipper
        |> AST.go_to_node(declaration)
        |> Zipper.update(fn {name, meta, nil} ->
          {String.to_atom("_#{name}"), meta, nil}
        end)
    end)
  end

  defp same_line_and_no_usages?({declaration, usages}, line),
    do: AST.starts_at?(declaration, line) and usages == []
end
