defmodule Expert.CodeIntelligence.Completion.Translations.StructFieldTest do
  use Expert.Test.Expert.CompletionCase

  alias GenLSP.Enumerations.CompletionItemKind

  test "a struct's fields are completed", %{project: project} do
    source = ~q[
      struct = %Project.Structs.User{}
      struct.f|
    ]

    assert {:ok, completion} =
             project
             |> complete(source)
             |> fetch_completion(kind: CompletionItemKind.field())

    assert completion.detail == "String.t()"
    assert completion.label == "first_name"
  end

  test "a struct's fields are completed when the struct is partially aliased", %{project: project} do
    source = ~q[
      alias Project.Structs
      struct = %Structs.User{}
      struct.f|
    ]

    assert {:ok, completion} =
             project
             |> complete(source)
             |> fetch_completion(kind: CompletionItemKind.field())

    assert completion.detail == "String.t()"
    assert completion.label == "first_name"
  end

  test "a struct's fields are completed when the struct is fully aliased", %{project: project} do
    source = ~q[
      alias Project.Structs.User
      struct = %User{}
      struct.f|
    ]

    assert {:ok, completion} =
             project
             |> complete(source)
             |> fetch_completion(kind: CompletionItemKind.field())

    assert completion.detail == "String.t()"
    assert completion.label == "first_name"
    assert apply_completion(completion) =~ "struct.first_name"
  end

  test "a struct's fields are completed when the struct is aliased using as", %{project: project} do
    source = ~q[
      alias Project.Structs.User, as: LocalUser
      struct = %LocalUser{}
      struct.f|
    ]

    assert {:ok, completion} =
             project
             |> complete(source)
             |> fetch_completion(kind: CompletionItemKind.field())

    assert completion.detail == "String.t()"
    assert completion.label == "first_name"
    assert apply_completion(completion) =~ "struct.first_name"
  end

  test "a struct defined in function arguments fields are completed", %{project: project} do
    source = ~q[
      defmodule MyModule do
        alias Project.Structs
        def my_fun(%Structs.User{} = user) do
          user.f|
        end
      end
    ]

    assert {:ok, completion} =
             project
             |> complete(source)
             |> fetch_completion(kind: CompletionItemKind.field())

    assert completion.detail == "String.t()"
    assert completion.label == "first_name"
    assert apply_completion(completion) =~ "user.first_name"
  end

  describe "in struct arguments" do
    def wrap_with_module(text) do
      """
      defmodule MyModule do
        #{text}
      end
      """
    end

    def find_by_label(completions, label_substring) do
      Enum.find(completions, &String.contains?(&1.label, label_substring))
    end

    test "should complete when after the curly", %{project: project} do
      {:ok, completions} =
        project
        |> complete(wrap_with_module("%Project.Structs.Account{|}"))
        |> fetch_completion(kind: CompletionItemKind.field())

      completion = find_by_label(completions, "last_login_at")
      expected = "%Project.Structs.Account{last_login_at: ${1:last_login_at}}"
      assert apply_completion(completion) =~ expected
    end

    test "should complete when typed a field character", %{project: project} do
      {:ok, completions} =
        project
        |> complete(wrap_with_module("%Project.Structs.Account{la|}"))
        |> fetch_completion(kind: CompletionItemKind.field())

      completion = find_by_label(completions, "last_login_at")
      expected = "%Project.Structs.Account{last_login_at: ${1:last_login_at}}"
      assert apply_completion(completion) =~ expected
    end

    test "should complete when after the comma", %{project: project} do
      {:ok, completions} =
        project
        |> complete(wrap_with_module("%Project.Structs.Account{last_login_at: nil, |}"))
        |> fetch_completion(kind: CompletionItemKind.field())

      completion = find_by_label(completions, "user")

      expected = "%Project.Structs.Account{last_login_at: nil, user: ${1:user}}"
      assert apply_completion(completion) =~ expected
    end

    test "should complete nothing when after the colon", %{project: project} do
      assert {:error, :not_found} ==
               project
               |> complete(wrap_with_module("%Project.Structs.Account{last_login_at: |}"))
               |> fetch_completion(kind: CompletionItemKind.field())
    end

    test "should complete when typed a field character after the comma", %{
      project: project
    } do
      source = ~q[
        defmodule MyModule do
          alias Project.Structs.Account

          def extract_user(account) do
            %Account{last_login_at: last_login_at, us|} = account
          end
        end
      ]

      expected = ~q[
        defmodule MyModule do
          alias Project.Structs.Account

          def extract_user(account) do
            %Account{last_login_at: last_login_at, user: ${1:user}} = account
          end
        end
      ]

      {:ok, completions} =
        project
        |> complete(source)
        |> fetch_completion(kind: CompletionItemKind.field())

      completion = find_by_label(completions, "user")
      assert apply_completion(completion) == expected
    end

    test "should complete when the struct module is aliased", %{project: project} do
      source = ~q[
        defmodule MyModule do
          alias Project.Structs.Account, as: LocalAccount

          def account(%LocalAccount{|} = account) do
            account
          end
        end
      ]

      expected = ~q[
        defmodule MyModule do
          alias Project.Structs.Account, as: LocalAccount

          def account(%LocalAccount{last_login_at: ${1:last_login_at}} = account) do
            account
          end
        end
      ]

      {:ok, completions} =
        project
        |> complete(source)
        |> fetch_completion(kind: CompletionItemKind.field())

      completion = find_by_label(completions, "last_login_at")
      assert apply_completion(completion) == expected
    end

    test "complete nothing when in the value position", %{project: project} do
      assert {:error, :not_found} ==
               project
               |> complete("%Project.Structs.Account{last_login_at: |}")
               |> fetch_completion(kind: CompletionItemKind.field())
    end

    test "complete nothing when the prefix is invalid", %{project: project} do
      assert {:error, :not_found} ==
               project
               |> complete("%Project.Structs.Account{l.|}")
               |> fetch_completion(kind: CompletionItemKind.field())
    end

    test "complete nothing when the module is not a struct", %{project: project} do
      assert {:error, :not_found} ==
               project
               |> complete("%Project.Structs.NotAStruct{|}")
               |> fetch_completion(kind: CompletionItemKind.field())
    end
  end
end
