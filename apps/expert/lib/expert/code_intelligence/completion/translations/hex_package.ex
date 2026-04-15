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

      # Insert with the leading `:` so `{:phoe` → `{:phoenix` regardless of
      # whether the builder's prefix range covers the `:` (unquoted atom
      # cursor_context) or only the bare word (local_or_var context). Either
      # way the result is a well-formed atom literal. The `filter_text`
      # keeps matching against the bare name so fuzzy matching on "phoe"
      # still works.
      env
      |> builder.plain_text(":" <> package.name,
        label: package.name,
        label_details: label_details,
        filter_text: package.name,
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
