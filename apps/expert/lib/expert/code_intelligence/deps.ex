defmodule Expert.CodeIntelligence.Deps do
  @moduledoc false

  @default_repo "hexpm"

  @doc """
  Walks `ast` looking for a `def deps` or `defp deps` arity-0 function and
  returns the literal list of dep tuple AST nodes inside its body.
  """
  @spec list(Macro.t()) :: {:ok, [Macro.t()]} | :error
  def list(ast) do
    case find_deps_body(ast) do
      {:ok, body} -> {:ok, collect_dep_tuples(body)}
      :error -> :error
    end
  end

  @doc """
  Returns `true` if `ast` contains a `deps/0` function whose body has a
  `:__cursor__` marker inserted by `Forge.Ast.reanalyze_to/2` — the signal
  that the user is mid-typing a dep and the real tuple content has been
  replaced by Forge's fragment-parsing recovery.
  """
  @spec cursor_in_deps_body?(Macro.t()) :: boolean()
  def cursor_in_deps_body?(ast) do
    case find_deps_body(ast) do
      {:ok, body} ->
        {_, found} =
          Macro.prewalk(body, false, fn
            {:__cursor__, _meta, _} = node, _ -> {node, true}
            other, acc -> {other, acc}
          end)

        found

      :error ->
        false
    end
  end

  defp find_deps_body(ast) do
    {_, found} =
      Macro.prewalk(ast, nil, fn
        {kind, _meta, [{:deps, _, args}, [{{:__block__, _, [:do]}, body}]]} = node, nil
        when kind in [:def, :defp] and (is_nil(args) or args == []) ->
          {node, body}

        other, acc ->
          {other, acc}
      end)

    case found do
      nil -> :error
      body -> {:ok, body}
    end
  end

  # Deeply walks the deps function body and collects every AST node that
  # *looks* like a dep tuple:
  #
  #   * `{:__block__, _, [{first, second}]}` — a literal 2-tuple, where
  #     `first` is an atom literal (the package name).
  #   * `{:{}, _, [first | _]}` — an explicit n-tuple with 3+ elements.
  #
  # Walking deeply (rather than matching a single list-shaped body) is what
  # makes this robust to Sourceror's parse-error recovery, which scatters the
  # surviving tuples into `:comma` / `:__block__` fragments when the user is
  # mid-edit.
  defp collect_dep_tuples(body) do
    {_, tuples} =
      Macro.prewalk(body, [], fn
        {:__block__, _meta, [{first, _second}]} = node, acc ->
          if atom_literal_node?(first), do: {node, [node | acc]}, else: {node, acc}

        {:{}, _meta, [first | _rest]} = node, acc ->
          if atom_literal_node?(first), do: {node, [node | acc]}, else: {node, acc}

        other, acc ->
          {other, acc}
      end)

    Enum.reverse(tuples)
  end

  defp atom_literal_node?({:__block__, _, [atom]}) when is_atom(atom), do: true
  defp atom_literal_node?(_), do: false

  @doc """
  Returns the hex repo name for a single dep tuple AST node.

  The conventions match Mix:
    * `repo: "name"` → `"name"` (literal repo name)
    * `organization: "org"` → `"hexpm:org"`
    * absent → `"hexpm"`

  `:repo` takes precedence over `:organization` when both are present, since
  Mix interprets `:repo` directly.
  """
  @spec repo_of(Macro.t()) :: String.t()
  def repo_of(tuple_ast) do
    opts = tuple_opts(tuple_ast)

    cond do
      repo = Keyword.get(opts, :repo) -> repo
      org = Keyword.get(opts, :organization) -> "hexpm:" <> org
      true -> @default_repo
    end
  end

  # 2-tuple literal: {:atom, "version"} — never has opts.
  defp tuple_opts({:__block__, _meta, [{_first, _second}]}), do: []

  # N-tuple via {:{}, meta, args}: opts may be the last positional arg as a
  # keyword list AST.
  defp tuple_opts({:{}, _meta, args}) when is_list(args) do
    args
    |> Enum.reverse()
    |> Enum.find_value([], &keyword_pairs/1)
  end

  defp tuple_opts(_), do: []

  defp keyword_pairs(list) when is_list(list) do
    list
    |> Enum.map(&keyword_pair/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      pairs -> pairs
    end
  end

  defp keyword_pairs(_), do: nil

  defp keyword_pair({{:__block__, _, [key]}, {:__block__, _, [value]}})
       when is_atom(key) and is_binary(value) do
    {key, value}
  end

  defp keyword_pair(_), do: nil
end
