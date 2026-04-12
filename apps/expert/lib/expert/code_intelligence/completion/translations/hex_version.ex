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
      tier_prefix = if version.retirement, do: "1", else: "0"
      sort_text = tier_prefix <> String.pad_leading(Integer.to_string(version.index), 4, "0")

      prefix_without_operator = strip_version_operator(version.prefix)
      prefix_length = String.length(prefix_without_operator)
      end_char = env.position.character
      start_char = max(end_char - prefix_length, 1)

      insert_text =
        if closing_quote_after_cursor?(env.document, env.position) do
          version.version
        else
          version.version <> "\""
        end

      {detail, documentation, tags, label_details} = retirement_decorations(version)
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

    defp closing_quote_after_cursor?(%Document{} = document, position) do
      case Document.fetch_text_at(document, position.line) do
        {:ok, line_text} ->
          rest = String.slice(line_text, (position.character - 1)..-1//1)
          String.contains?(rest, "\"")

        _ ->
          false
      end
    end

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

    defp operator_prefix(nil), do: ""

    defp operator_prefix(prefix) when is_binary(prefix) do
      case Regex.run(~r/^(?:~>|>=|<=|!=|==|>|<)\s*/, prefix) do
        [op] -> op
        nil -> ""
      end
    end

    defp strip_version_operator(nil), do: ""

    defp strip_version_operator(prefix) when is_binary(prefix) do
      Regex.replace(~r/^(?:~>|>=|<=|!=|==|>|<)\s*/, prefix, "")
    end

    defp maybe_put(options, _key, nil), do: options
    defp maybe_put(options, _key, []), do: options
    defp maybe_put(options, key, value), do: Keyword.put(options, key, value)
  end
end
