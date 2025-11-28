defmodule Expert.CodeIntelligence.Completion.SortScope do
  @moduledoc """
  Enumerated categories for sorting completion items.

  The following options are available for all categories, spare variables
  which cannot be deprecated.
    * `deprecated?` - Indicates the completion is for a deprecated declaration.
      Defaults to `false`.

    * `local_priority` - An integer from 0-9 highest-to-lowest for
    prioritizing/sorting results within a given scope. Defaults to `1`.
  """

  @doc """
  Intended for module completions, such as `Expert.` -> `Expert.Completion`.
  """
  def module(local_priority \\ 1) do
    "0" <> "0" <> local_priority(local_priority)
  end

  @doc """
  Intended for variables, which are always local in scope.
  """
  def variable(local_priority \\ 1) do
    "1" <> "0" <> local_priority(local_priority)
  end

  @doc """
  Intended for declarations (functions and macros) defined in the immediate
  module, or inherited from invoking `use`.
  """
  def local(deprecated? \\ false, local_priority \\ 1) do
    "2" <> extra_order_fields(deprecated?, local_priority)
  end

  @doc """
  Intended for declarations defined in other modules than the immediate scope,
  either from one's project, dependencies, or the standard library.
  """
  def remote(deprecated? \\ false, local_priority \\ 1) do
    "3" <> extra_order_fields(deprecated?, local_priority)
  end

  @doc """
  Intended for declarations available without aliasing, namely those in
  `Kernel` and `Kernel.SpecialForms`.
  """
  def global(deprecated? \\ false, local_priority \\ 1) do
    "4" <> extra_order_fields(deprecated?, local_priority)
  end

  @doc """
  Aspirationally for declarations that could be auto-aliased into the user's
  immediate module (not yet a feature of Expert).
  """
  def auto(deprecated? \\ false, local_priority \\ 1) do
    "5" <> extra_order_fields(deprecated?, local_priority)
  end

  @doc """
  Sorting scope applied to completions that without any sorting scope applied.
  """
  def default(deprecated? \\ false, local_priority \\ 1) do
    "9" <> extra_order_fields(deprecated?, local_priority)
  end

  defp extra_order_fields(deprecated?, local_priority) do
    deprecated(deprecated?) <> local_priority(local_priority)
  end

  defp deprecated(false), do: "0"
  defp deprecated(true), do: "1"

  defp local_priority(x) when x in 0..9 do
    Integer.to_string(x)
  end
end
