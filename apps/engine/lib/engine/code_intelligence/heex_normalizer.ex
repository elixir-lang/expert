defmodule Engine.CodeIntelligence.HeexNormalizer do
  @moduledoc false

  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Sourceror.Zipper

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
  @spec call(Analysis.t(), Position.t()) :: Analysis.t()
  def call(analysis, position) do
    new_ast = normalize_ast(analysis, position)
    new_document = normalize_document(analysis, position)
    %{analysis | ast: new_ast, document: new_document}
  end

  defp normalize_ast(analysis, position) do
    with {:ok, path} <- Ast.path_at(analysis, position),
         {:sigil_H, _, _} = sigil <- Enum.find(path, &match?({:sigil_H, _, _}, &1)) do
      new_sigil = normalize_heex_node(sigil)

      analysis.ast
      |> Zipper.zip()
      |> Zipper.find(&(&1 == sigil))
      |> case do
        nil -> analysis.ast
        zipper -> zipper |> Zipper.replace(new_sigil) |> Zipper.root()
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
end
