defmodule Expert.CodeIntelligence.Completion.Translations.MapFieldTest do
  use Expert.Test.Expert.CompletionCase

  alias GenLSP.Enumerations.CompletionItemKind

  test "a map's fields are completed", %{project: project} do
    source = ~q[
      user = %{first_name: "John", last_name: "Doe"}
      user.f|
    ]

    assert {:ok, completion} =
             project
             |> complete(source)
             |> fetch_completion(kind: CompletionItemKind.field())

    assert completion.detail == "first_name"
    assert apply_completion(completion) =~ "user.first_name"
  end

  test "a map's fields are completed after a dot", %{project: project} do
    source = ~q[
      user = %{first_name: "John", last_name: "Doe"}
      user.|
    ]

    assert {:ok, [first_name, last_name]} =
             project
             |> complete(source)
             |> fetch_completion(kind: CompletionItemKind.field())

    assert apply_completion(first_name) =~ "user.first_name"
    assert apply_completion(last_name) =~ "user.last_name"
  end
end
