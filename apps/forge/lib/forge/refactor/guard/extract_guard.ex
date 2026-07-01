# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Forge.Refactor.Guard.ExtractGuard do
  use Forge.Refactor,
    title: "Extract guard",
    kind: "refactor.extract",
    works_on: :selection

  alias Forge.Refactor.Dataflow
  alias Forge.Refactor.Guard
  alias Forge.Refactor.Module
  alias Forge.Refactor.NameCache

  @guard_name "extracted_guard"

  def can_refactor?(%{node: node} = zipper, selection) do
    cond do
      not AST.equal?(node, selection) ->
        false

      not Module.inside_one?(zipper) ->
        false

      not Guard.guard_statement?(zipper) ->
        false

      true ->
        true
    end
  end

  def refactor(%{node: node} = zipper, _) do
    name = next_available_guard_name(zipper)
    args = Dataflow.outer_variables(node)

    zipper
    |> Zipper.replace({name, [], args})
    |> Guard.new_private_guard(name, args, node)
  end

  defp next_available_guard_name(zipper) do
    NameCache.consume_name_or(fn ->
      Module.next_available_name(
        zipper,
        @guard_name,
        &Guard.definition?/1,
        fn {_, _, [{:when, _, [{name, _, _} | _]}]} -> name end
      )
    end)
  end
end
