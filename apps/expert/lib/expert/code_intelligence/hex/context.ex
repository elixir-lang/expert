defmodule Expert.CodeIntelligence.Hex.Context do
  @moduledoc """
  Detects whether a position inside a `mix.exs` document is sitting in the
  `deps/0` function and, if so, which dependency tuple slot the cursor is in.
  """

  alias Expert.CodeIntelligence.Deps
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Position

  @type slot :: :name | :version | :opts

  @type t :: %{
          slot: slot(),
          prefix: String.t(),
          package: String.t() | nil,
          repo: String.t()
        }

  @spec detect(Analysis.t(), Position.t()) :: {:ok, t()} | :error
  def detect(%Analysis{} = analysis, %Position{} = position) do
    # Prefer Sourceror's permissive whole-file parse over the fragment-
    # parsed `analysis.ast`. Forge's `reanalyze_to/2` pipeline truncates
    # the document at the cursor and replaces the in-progress expression
    # with a `:__cursor__` marker — useful for Elixir-scope awareness but
    # destructive for tuple-in-list detection because it discards the real
    # deps tuples. Sourceror's error-recovering parser keeps them.
    with ast when not is_nil(ast) <- permissive_ast(analysis.document),
         {:ok, deps_list} <- Deps.list(ast) do
      case find_tuple_at(deps_list, position) do
        {:ok, tuple} ->
          with {:ok, slot, package} <- slot_for_tuple(tuple, position),
               {:ok, prefix} <- extract_prefix(analysis.document, position, slot) do
            {:ok, %{slot: slot, prefix: prefix, package: package, repo: Deps.repo_of(tuple)}}
          else
            _ -> :error
          end

        :error ->
          cursor_fallback(analysis, position)
      end
    else
      _ -> line_fallback(analysis.document, position)
    end
  end

  # Last-resort fallback when both parsers fail completely (e.g. an unclosed
  # string like `{:oban_pro, "` swallows the rest of the file). Detects the
  # slot purely from the raw line text — no AST needed.
  defp line_fallback(%Document{} = document, %Position{} = position) do
    case version_from_line(document, position) do
      {:ok, package, prefix} ->
        {:ok, %{slot: :version, prefix: prefix, package: package, repo: "hexpm"}}

      :error ->
        :error
    end
  end

  defp permissive_ast(%Document{} = document) do
    case Ast.from(document) do
      {:ok, ast, _comments} -> ast
      {:error, ast, _parse_error, _comments} -> ast
      _ -> nil
    end
  end

  # Fallback when Sourceror's parse found the `deps/0` function but no
  # tuple literal covers the cursor position. This typically means the
  # user is mid-typing a brand-new dep that Sourceror hasn't recovered as
  # a tuple shape. If Forge's fragment-parsed analysis confirms a
  # `:__cursor__` marker inside the deps body — the cleanest signal that
  # the cursor is actually inside the list — extract a `:name` slot prefix
  # from the raw line text and return that.
  defp cursor_fallback(%Analysis{} = analysis, %Position{} = position) do
    if cursor_inside_deps?(analysis) do
      case version_from_line(analysis.document, position) do
        {:ok, package, prefix} ->
          {:ok, %{slot: :version, prefix: prefix, package: package, repo: "hexpm"}}

        :error ->
          case extract_prefix(analysis.document, position, :name) do
            {:ok, prefix} when byte_size(prefix) > 0 ->
              {:ok, %{slot: :name, prefix: prefix, package: nil, repo: "hexpm"}}

            _ ->
              :error
          end
      end
    else
      :error
    end
  end

  # Detects `{:package, "prefix` on the current line when the parser
  # couldn't recover the tuple (typically an unclosed version string).
  defp version_from_line(%Document{} = document, %Position{} = position) do
    with {:ok, line_text} <- Document.fetch_text_at(document, position.line),
         before = String.slice(line_text, 0, position.character - 1),
         [_, package, prefix] <- Regex.run(~r/\{:(\w+),\s*"([^"]*)$/, before) do
      {:ok, package, prefix}
    else
      _ -> :error
    end
  end

  defp cursor_inside_deps?(%Analysis{ast: nil}), do: false
  defp cursor_inside_deps?(%Analysis{ast: ast}), do: Deps.cursor_in_deps_body?(ast)

  defp find_tuple_at(deps_list, position) do
    Enum.find_value(deps_list, :error, fn node ->
      if tuple_node?(node) and position_in?(node_meta(node), position) do
        {:ok, node}
      end
    end)
  end

  defp tuple_node?({:__block__, _meta, [{_, _}]}), do: true
  defp tuple_node?({:{}, _meta, _args}), do: true
  defp tuple_node?(_), do: false

  defp node_meta({:__block__, meta, _}), do: meta
  defp node_meta({:{}, meta, _}), do: meta

  defp position_in?(meta, %Position{line: pl, character: pc}) do
    with {:ok, ol} <- Keyword.fetch(meta, :line),
         {:ok, oc} <- Keyword.fetch(meta, :column) do
      case closing_bounds(meta) do
        {:ok, cl, cc} ->
          {pl, pc} >= {ol, oc} and {pl, pc} <= {cl, cc + 1}

        :error ->
          pl == ol and pc >= oc
      end
    else
      _ -> false
    end
  end

  defp closing_bounds(meta) do
    with closing when is_list(closing) <- Keyword.get(meta, :closing),
         {:ok, cl} <- Keyword.fetch(closing, :line),
         {:ok, cc} <- Keyword.fetch(closing, :column) do
      {:ok, cl, cc}
    else
      _ -> :error
    end
  end

  defp slot_for_tuple({:__block__, _meta, [{first, second}]}, position) do
    classify(position, [first, second])
  end

  defp slot_for_tuple({:{}, _meta, args}, position) do
    classify(position, args)
  end

  defp classify(position, [first | _] = args) do
    package = package_name(first)
    {name_node, version_node} = {Enum.at(args, 0), Enum.at(args, 1)}

    cond do
      node_covers?(name_node, position) ->
        {:ok, :name, package}

      version_node != nil and node_covers?(version_node, position) ->
        {:ok, :version, package}

      length(args) >= 3 ->
        {:ok, :opts, package}

      version_node != nil and is_binary(package) and
        not clean_binary_arg?(version_node) and
          past_first_arg?(args, position) ->
        {:ok, :version, package}

      true ->
        :error
    end
  end

  defp classify(_position, []), do: :error

  defp past_first_arg?([{:__block__, meta, [value]} | _], %Position{} = position)
       when is_atom(value) do
    node_line = Keyword.get(meta, :line)
    node_col = Keyword.get(meta, :column)

    if is_integer(node_line) and is_integer(node_col) do
      atom_end_col = node_col + String.length(Atom.to_string(value)) + 1
      {position.line, position.character} > {node_line, atom_end_col}
    else
      false
    end
  end

  defp past_first_arg?(_, _), do: false

  defp clean_binary_arg?({:__block__, _meta, [value]}) when is_binary(value), do: true
  defp clean_binary_arg?(_), do: false

  defp package_name({:__block__, _, [atom]}) when is_atom(atom), do: Atom.to_string(atom)
  defp package_name(_), do: nil

  defp node_covers?({:__block__, meta, [value]}, %Position{} = position) do
    line = Keyword.get(meta, :line)
    col = Keyword.get(meta, :column)

    cond do
      is_nil(line) or is_nil(col) ->
        false

      position.line != line ->
        false

      true ->
        position.character >= col and
          position.character <= col + cursor_max_offset(value, meta)
    end
  end

  defp node_covers?(_, _), do: false

  defp cursor_max_offset(value, _meta) when is_atom(value) do
    String.length(Atom.to_string(value)) + 1
  end

  defp cursor_max_offset(value, meta) when is_binary(value) do
    delim = Keyword.get(meta, :delimiter, "\"")
    String.length(value) + 2 * String.length(delim) - 1
  end

  defp cursor_max_offset(_value, _meta), do: 0

  defp extract_prefix(%Document{} = document, %Position{} = position, slot) do
    with {:ok, line_text} <- Document.fetch_text_at(document, position.line) do
      col = position.character - 1
      before = String.slice(line_text, 0, col)
      {:ok, slot_prefix(slot, before)}
    end
  end

  defp slot_prefix(:name, before) do
    case :binary.matches(before, ":") do
      [] ->
        ""

      matches ->
        {pos, _} = List.last(matches)
        String.slice(before, (pos + 1)..-1//1)
    end
  end

  defp slot_prefix(:version, before) do
    case :binary.matches(before, "\"") do
      [] ->
        ""

      matches ->
        {pos, _} = List.last(matches)
        String.slice(before, (pos + 1)..-1//1)
    end
  end

  defp slot_prefix(:opts, before) do
    boundary =
      before
      |> :binary.matches([",", "{"])
      |> Enum.map(fn {p, _} -> p end)
      |> Enum.max(fn -> -1 end)

    before
    |> String.slice((boundary + 1)..-1//1)
    |> String.trim_leading()
  end
end
