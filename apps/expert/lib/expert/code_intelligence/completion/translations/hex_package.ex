defmodule Expert.CodeIntelligence.Completion.Translations.HexPackage do
  @moduledoc false

  alias Expert.CodeIntelligence.Completion.SortScope
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Expert.CodeIntelligence.Hex.Candidate
  alias Forge.Ast.Env
  alias GenLSP.Enumerations.CompletionItemKind
  alias GenLSP.Structures.CompletionItemLabelDetails

  defimpl Translatable, for: Candidate.Package do
    def translate(%Candidate.Package{} = package, builder, %Env{} = env) do
      label_details = %CompletionItemLabelDetails{
        detail: package.latest_version && " #{package.latest_version}",
        description: repo_label(package.repo)
      }

      # Insert with the leading `:` so `{:phoe` → `{:phoenix`. The cursor sits
      # on an unquoted atom (a colon is always present when we reach this
      # slot), so the builder's replacement range covers the `:` too.
      #
      # `filter_text` must span that same range, otherwise a client that
      # filters the typed word against `filter_text` (e.g. VS Code) matches
      # `:phoe` against `phoenix`, fails, and drops the item.
      name_with_colon = ":" <> package.name

      env
      |> builder.plain_text(name_with_colon,
        label: package.name,
        label_details: label_details,
        filter_text: name_with_colon,
        kind: CompletionItemKind.module(),
        detail: "hex",
        documentation: package.description
      )
      |> builder.set_sort_scope(SortScope.module(0))
    end

    defp repo_label("hexpm"), do: nil
    defp repo_label(repo) when is_binary(repo), do: repo
    defp repo_label(_), do: nil
  end
end
