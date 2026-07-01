# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Forge.Refactor.Function.ExtractFunction do
  use Forge.Refactor,
    title: "Extract function",
    kind: "refactor.extract",
    works_on: :selection

  alias Forge.Refactor.Dataflow
  alias Forge.Refactor.Function
  alias Forge.Refactor.Module
  alias Forge.Refactor.Pipeline
  alias Forge.Refactor.Variable

  @function_name "extracted_function"

  def can_refactor?(%{node: {id, _, _}}, _)
      when id in ~w(@ & <- alias __aliases__)a,
      do: :skip

  def can_refactor?(%{node: node} = zipper, selection) do
    cond do
      not Module.inside_one?(zipper) ->
        false

      Variable.inside_declaration?(zipper) ->
        false

      AST.equal?(node, selection) ->
        true

      Pipeline.starts_at?(selection, node) ->
        true

      true ->
        false
    end
  end

  def refactor(%{node: node} = zipper, selection) do
    name = Function.next_available_function_name(zipper, @function_name)
    args = Dataflow.outer_variables(selection)
    new_arg = {:arg1, [], nil}

    cond do
      Pipeline.starts_at?(selection, node) ->
        %{node: {:|>, _, [before, _]}} = Zipper.up(zipper)

        zipper
        |> Pipeline.go_to_top(selection)
        |> Zipper.replace({:|>, [], [before, {name, [], args}]})
        |> Function.new_private_function(
          name,
          [new_arg | args],
          Pipeline.update_start(selection, &{:|>, [], [new_arg, &1]})
        )

      match?(%{node: {:|>, _, [_, ^node]}}, Zipper.up(zipper)) ->
        zipper
        |> Zipper.replace({name, [], args})
        |> Function.new_private_function(
          name,
          [new_arg | args],
          {:|>, [], [new_arg, selection]}
        )

      true ->
        zipper
        |> Zipper.replace({name, [], args})
        |> Function.new_private_function(name, args, selection)
    end
  end
end
