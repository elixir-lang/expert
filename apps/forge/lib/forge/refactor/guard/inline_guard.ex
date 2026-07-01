# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Forge.Refactor.Guard.InlineGuard do
  use Forge.Refactor,
    title: "Inline guard",
    kind: "refactor.inline",
    works_on: :selection

  alias Forge.Refactor.Guard
  alias Forge.Refactor.Module
  alias Forge.Refactor.Variable

  def can_refactor?(%{node: node} = zipper, selection) do
    cond do
      not AST.equal?(node, selection) ->
        false

      not Module.inside_one?(zipper) ->
        false

      not Guard.guard_statement?(zipper) ->
        false

      Guard.definition?(AST.up(zipper, 2)) ->
        false

      is_nil(Guard.find_definition(zipper)) ->
        false

      true ->
        true
    end
  end

  def refactor(%{node: {_, _, call_values}} = zipper, _) do
    {_, _, [{_, _, [{_, _, args}, body]}]} = definition = Guard.find_definition(zipper)

    body
    |> Variable.replace_variables_by_values(args, call_values, definition)
    |> then(&Zipper.replace(zipper, &1))
  end
end
