defmodule Expert.CodeIntelligence.Completion.Translations.HexOpt do
  @moduledoc false

  alias Expert.CodeIntelligence.Completion.SortScope
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Expert.CodeIntelligence.Hex.Candidate
  alias Forge.Ast.Env
  alias GenLSP.Enumerations.CompletionItemKind
  alias GenLSP.Structures.CompletionItemLabelDetails

  defimpl Translatable, for: Candidate.Opt do
    def translate(%Candidate.Opt{} = opt, builder, %Env{} = env) do
      label_details = %CompletionItemLabelDetails{description: opt.description}

      env
      |> builder.plain_text(opt.name <> ": ",
        label: opt.name,
        label_details: label_details,
        kind: CompletionItemKind.field(),
        detail: "Mix.Project dep option",
        documentation: opt.description
      )
      |> builder.set_sort_scope(SortScope.module(0))
    end
  end
end
