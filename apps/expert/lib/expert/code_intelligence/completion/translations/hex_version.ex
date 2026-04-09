defmodule Expert.CodeIntelligence.Completion.Translations.HexVersion do
  @moduledoc false

  alias Expert.CodeIntelligence.Completion.SortScope
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Expert.CodeIntelligence.Hex.Candidate
  alias Forge.Ast.Env
  alias Forge.Document
  alias GenLSP.Enumerations.CompletionItemKind
  alias GenLSP.Enumerations.CompletionItemTag
  alias GenLSP.Structures.CompletionItemLabelDetails

  defimpl Translatable, for: Candidate.Version do
    def translate(%Candidate.Version{} = version, builder, %Env{} = env) do
      # Two-tier sort: active releases come first, retired ones below.
      # Within each tier, pad the index so newer versions sort above
      # older versions. The 4-digit pad assumes < 10000 releases per
      # package. The tier prefix (`0`/`1`) is what pushes retired
      # versions below active ones regardless of semver ordering.
      tier_prefix = if version.retirement, do: "1", else: "0"
      sort_text = tier_prefix <> String.pad_leading(Integer.to_string(version.index), 4, "0")

      # Explicit text-edit range: cover the text the user has already
      # typed inside the version literal. `plain_text/3`'s
      # `cursor_context` heuristic can't classify a position inside an
      # unclosed string as anything replaceable, so without an explicit
      # range, completing `"~> 3|` with `3.0` would concatenate to
      # `"~> 33.0`.
      #
      # If the user's prefix starts with an operator (`~>`, `>=`, etc.),
      # leave that part alone so accepting preserves their intent — only
      # the version digits past it are replaced. `"~> 3|` + accept
      # `3.0.0` → `"~> 3.0.0`, not `"3.0.0` (losing the operator).
      prefix_without_operator = strip_version_operator(version.prefix)

      prefix_length = String.length(prefix_without_operator)
      end_char = env.position.character
      start_char = max(end_char - prefix_length, 1)

      # Auto-close the version string when the user is mid-typing
      # inside an unclosed literal — `"~> 3|` + accepting `3.0.0` →
      # `"~> 3.0.0"` instead of `"~> 3.0.0`. When there's already a
      # closing `"` after the cursor on the same line (e.g. `"~> 3|"`
      # or `"~> 3|.0"`), leave the insert text alone so we don't emit
      # a second closing quote.
      insert_text =
        if closing_quote_after_cursor?(env.document, env.position) do
          version.version
        else
          version.version <> "\""
        end

      {detail, documentation, tags, label_details} = retirement_decorations(version)

      # Include the operator prefix in `filter_text` so the user's typed
      # input remains a subsequence of the filter across the full typing
      # path. For example, `"|` → `"~|` → `"~>|` → `"~> |` → `"~> 1|`
      # all match `"~> 1.7.14"` as a subsequence, preventing the client
      # from hiding items between keystrokes. The operator is extracted
      # from the user's actual prefix so this works for `>=`, `==`, etc.
      # — not just `~>`. When no operator is present (bare version),
      # the filter text is just the version number.
      filter_text = operator_prefix(version.prefix) <> version.version

      options =
        [
          label: version.version,
          label_details: label_details,
          filter_text: filter_text,
          kind: CompletionItemKind.value(),
          detail: detail
        ]
        |> maybe_put(:documentation, documentation)
        |> maybe_put(:tags, tags)

      item =
        env
        |> builder.text_edit(insert_text, {start_char, end_char}, options)
        |> builder.set_sort_scope(SortScope.module(0))

      %{item | sort_text: sort_text}
    end

    # Scans the current line from the cursor to the end, looking for
    # the closing `"` of a version literal. Returns `true` if one
    # exists anywhere after the cursor on the same line — meaning the
    # user is editing inside an already-closed string and we should
    # not emit a second closing quote on accept.
    defp closing_quote_after_cursor?(%Document{} = document, position) do
      case Document.fetch_text_at(document, position.line) do
        {:ok, line_text} ->
          # `position.character` is 1-indexed. `String.slice/2` is
          # 0-indexed, so the first char at-or-after the cursor lives
          # at index `position.character - 1`.
          rest = String.slice(line_text, (position.character - 1)..-1//1)
          String.contains?(rest, "\"")

        _ ->
          false
      end
    end

    # Active releases: plain package-name detail, no tags, no docs, no
    # label details. The version menu is cleaner when the only thing
    # next to a version number is the retirement marker — package name
    # and other ornaments just add noise when every candidate in the
    # list is for the same package anyway.
    #
    # Retired releases: `package • retired (<reason>)` detail, the
    # maintainer's message (if any) as hover documentation, the LSP
    # `Deprecated` tag so clients render them with strikethrough, and
    # a minimal `label_details` with `" (retired)"` inline and the
    # reason in the faint right column.
    defp retirement_decorations(%Candidate.Version{retirement: nil, package: package}) do
      {package, nil, nil, nil}
    end

    defp retirement_decorations(%Candidate.Version{retirement: retirement, package: package}) do
      reason = Map.get(retirement, :reason) || "retired"
      detail = "#{package} • retired (#{reason})"

      documentation =
        case Map.get(retirement, :message) do
          msg when is_binary(msg) and msg != "" -> msg
          _ -> nil
        end

      label_details = %CompletionItemLabelDetails{
        detail: " (retired)",
        description: reason
      }

      {detail, documentation, [CompletionItemTag.deprecated()], label_details}
    end

    # Extracts the operator + trailing space from the prefix (e.g. "~> "
    # from "~> 1.7"), or "" when no operator is present (bare version).
    defp operator_prefix(nil), do: ""

    defp operator_prefix(prefix) when is_binary(prefix) do
      case Regex.run(~r/^(?:~>|>=|<=|!=|==|>|<)\s*/, prefix) do
        [op] -> op
        nil -> ""
      end
    end

    # Strips version requirement operators from the user's typed prefix,
    # leaving only the version digits that the text-edit range should cover.
    defp strip_version_operator(nil), do: ""

    defp strip_version_operator(prefix) when is_binary(prefix) do
      Regex.replace(~r/^(?:~>|>=|<=|!=|==|>|<)\s*/, prefix, "")
    end

    defp maybe_put(options, _key, nil), do: options
    defp maybe_put(options, _key, []), do: options
    defp maybe_put(options, key, value), do: Keyword.put(options, key, value)
  end
end
