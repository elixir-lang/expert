defmodule Engine.CodeIntelligence.Heex do
  @moduledoc false

  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Sourceror.FastZipper

  # Matches both opening and closing shorthand components (used for cursor detection)
  @component_regex ~r/<\/?\.([a-zA-Z0-9_!?.]+)/
  # Separate regexes for AST normalization to avoid overlap issues
  @opening_component_regex ~r/<\.([a-zA-Z0-9_!?.]+)/
  @closing_component_regex ~r/<\/\.([a-zA-Z0-9_!?.]+)/
  @opening_replacement "< \\1(assigns)"
  @closing_replacement "</ \\1(assigns)"

  # Normalizes HEEx templates by converting anonymous component references
  # (e.g., `<.component`) to explicit function calls (e.g., `<component(assigns)`).
  # It's done in both the AST and document text.
  #
  # This allows ElixirSense to understand the shorthand HEEX notation as a local function
  # (be it imported or not) and return correct location for go-to-definition and hover.
  #
  # This normalization is only performed when Phoenix.Component is available in the project
  # (i.e., phoenix_live_view is in the dependencies).
  @spec maybe_normalize(Analysis.t(), Position.t()) :: Analysis.t()
  def maybe_normalize(analysis, position) do
    if phoenix_component_available?() do
      new_ast = normalize_ast(analysis, position)
      new_document = normalize_document(analysis, position)
      %{analysis | ast: new_ast, document: new_document}
    else
      analysis
    end
  end

  # Extracts the arity of a function call inside a `~H` sigil.
  #
  # Uses EEx tokenization to find the expression at the cursor position,
  # then parses it and extracts the arity from the AST.
  @spec arity(Macro.t(), Position.t(), (list(), Position.t() -> non_neg_integer())) ::
          non_neg_integer()
  def arity({:sigil_H, meta, [{:<<>>, _, parts}, _]}, position, arity_at_position) do
    content = sigil_content(parts)
    sigil_start_line = Keyword.get(meta, :line, 1)
    sigil_start_column = Keyword.get(meta, :column, 1)
    relative_line = position.line - sigil_start_line
    # calculate relative column (only meaningful when on first line of sigil content)
    relative_column = position.character - sigil_start_column

    with {:ok, tokens} <- EEx.tokenize(content),
         {:ok, expr} <- find_expr_at(tokens, relative_line, relative_column),
         {:ok, ast} <- Code.string_to_quoted(List.to_string(expr)) do
      arity_at_position.([ast], position)
    else
      # component shorthand like `<.button>` - after normalization has arity 1
      :component_shorthand -> 1
      _ -> 0
    end
  end

  def arity(_, _, _), do: 0

  defp phoenix_component_available? do
    Engine.Module.Loader.ensure_loaded?(Phoenix.Component)
  end

  defp normalize_ast(analysis, position) do
    with {:ok, path} <- Ast.path_at(analysis, position),
         {:sigil_H, _, _} = sigil <- Enum.find(path, &match?({:sigil_H, _, _}, &1)) do
      new_sigil = normalize_heex_node(sigil)

      analysis.ast
      |> FastZipper.zip()
      |> FastZipper.find(&(&1 == sigil))
      |> case do
        nil -> analysis.ast
        zipper -> zipper |> FastZipper.replace(new_sigil) |> FastZipper.root()
      end
    else
      _ -> analysis.ast
    end
  end

  defp normalize_document(analysis, position) do
    case extract_heex_range(analysis, position) do
      {:ok, _sigil, start_pos, end_pos} ->
        start_pos = Position.new(analysis.document, start_pos[:line], start_pos[:column])
        end_pos = Position.new(analysis.document, end_pos[:line], end_pos[:column])
        range = Range.new(start_pos, end_pos)

        original_text = Document.fragment(analysis.document, start_pos, end_pos)
        new_text = normalize_heex_text(analysis.document, original_text, position, start_pos)

        change = %{range: range, text: new_text}

        case Document.apply_content_changes(analysis.document, analysis.document.version + 1, [
               change
             ]) do
          {:ok, doc} -> doc
          _ -> analysis.document
        end

      _ ->
        analysis.document
    end
  end

  defp extract_heex_range(analysis, position) do
    with {:ok, path} <- Ast.path_at(analysis, position),
         {:sigil_H, _, _} = sigil <- Enum.find(path, &match?({:sigil_H, _, _}, &1)),
         %{start: start_pos, end: end_pos} <- Sourceror.get_range(sigil) do
      {:ok, sigil, start_pos, end_pos}
    else
      _ -> :error
    end
  end

  defp normalize_heex_text(document, original_text, cursor_position, start_pos) do
    text_before = Document.fragment(document, start_pos, cursor_position)
    cursor_offset = byte_size(text_before)

    case find_component_match(original_text, cursor_offset) do
      {match_start, match_length, component_name, is_closing} ->
        build_replacement_text(
          original_text,
          match_start,
          match_length,
          component_name,
          is_closing
        )

      nil ->
        original_text
    end
  end

  defp find_component_match(text, cursor_offset) do
    matches = Regex.scan(@component_regex, text, return: :index)

    Enum.find_value(matches, fn
      [{match_start, match_len}, {name_start, name_len}] ->
        if cursor_offset >= match_start and cursor_offset <= match_start + match_len do
          matched_text = binary_part(text, match_start, match_len)
          component_name = binary_part(text, name_start, name_len)
          is_closing = String.starts_with?(matched_text, "</")
          {match_start, match_len, component_name, is_closing}
        else
          nil
        end
    end)
  end

  defp build_replacement_text(
         original_text,
         match_start,
         match_length,
         component_name,
         is_closing
       ) do
    prefix = binary_part(original_text, 0, match_start)

    suffix =
      binary_part(
        original_text,
        match_start + match_length,
        byte_size(original_text) - (match_start + match_length)
      )

    replacement =
      if is_closing do
        "</ #{component_name}(assigns)"
      else
        "< #{component_name}(assigns)"
      end

    prefix <> replacement <> suffix
  end

  defp normalize_heex_node({:sigil_H, meta, [{:<<>>, string_meta, parts}, modifiers]})
       when is_list(parts) do
    new_parts =
      Enum.map(parts, fn
        part when is_binary(part) ->
          part
          |> then(&Regex.replace(@closing_component_regex, &1, @closing_replacement))
          |> then(&Regex.replace(@opening_component_regex, &1, @opening_replacement))

        other ->
          other
      end)

    {:sigil_H, meta, [{:<<>>, string_meta, new_parts}, modifiers]}
  end

  defp normalize_heex_node(node), do: node

  defp sigil_content(parts) when is_list(parts) do
    Enum.map_join(parts, fn
      part when is_binary(part) -> part
      {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [_expr]}, {:binary, _, _}]} -> "${}"
      _ -> ""
    end)
  end

  defp find_expr_at(tokens, target_line, target_column) do
    Enum.find_value(tokens, :component_shorthand, fn
      {:expr, _marker, expr, %{line: line, column: col}} when line == target_line ->
        # check if cursor is within this expression's column range
        expr_length = length(expr)

        if target_column >= col and target_column <= col + expr_length do
          {:ok, expr}
        else
          nil
        end

      {:text, text, %{line: start_line, column: start_col}} ->
        text_str = List.to_string(text)
        line_in_text = target_line - start_line
        # calculate column offset within the text
        text_column = if line_in_text == 0, do: target_column - start_col, else: target_column
        find_curly_expr_at_line(text_str, line_in_text, text_column)

      _ ->
        nil
    end)
  end

  defp find_curly_expr_at_line(text, line_offset, cursor_column) do
    lines = String.split(text, "\n")

    if line_offset >= 0 and line_offset < length(lines) do
      line = Enum.at(lines, line_offset)

      # check if cursor on a component shorthand
      if cursor_on_component_shorthand?(line, cursor_column) do
        :component_shorthand
      else
        # check if cursor inside a curly expression
        find_curly_expr_at_column(line, cursor_column)
      end
    else
      nil
    end
  end

  defp cursor_on_component_shorthand?(line, cursor_column) do
    @component_regex
    |> Regex.scan(line, return: :index)
    |> Enum.any?(fn [{match_start, match_len} | _] ->
      cursor_column >= match_start and cursor_column < match_start + match_len
    end)
  end

  defp find_curly_expr_at_column(line, cursor_column) do
    ~r/\{([^{}]+)\}/
    |> Regex.scan(line, return: :index)
    |> Enum.find_value(fn [{match_start, match_len}, {expr_start, expr_len}] ->
      if cursor_column >= match_start and cursor_column < match_start + match_len do
        expr = binary_part(line, expr_start, expr_len)
        {:ok, String.to_charlist(expr)}
      end
    end)
  end
end
