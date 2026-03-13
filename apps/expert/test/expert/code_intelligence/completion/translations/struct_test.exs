defmodule Expert.CodeIntelligence.Completion.Translations.StructTest do
  use Expert.Test.Expert.CompletionCase

  alias GenLSP.Enumerations.CompletionItemKind

  describe "structs" do
    test "should complete after %", %{project: project} do
      assert {:ok, [_, _, _] = account_and_user_and_order} =
               project
               |> complete("%Project.Structs.|")
               |> fetch_completion(kind: CompletionItemKind.struct())

      assert Enum.find(account_and_user_and_order, &(&1.label == "User"))
      account = Enum.find(account_and_user_and_order, &(&1.label == "Account"))
      assert account
      assert account.detail == "Project.Structs.Account"

      assert apply_completion(account) == "%Project.Structs.Account{$1}"
    end

    test "should complete after a dot", %{project: project} do
      assert {:ok, account} =
               project
               |> complete("%Project.Structs.A|")
               |> fetch_completion(kind: CompletionItemKind.struct())

      assert account
      assert account.detail == "Project.Structs.Account"

      assert apply_completion(account) == "%Project.Structs.Account{$1}"
    end

    test "should complete aliases after %", %{project: project} do
      source = ~q[
        alias Project.Structs.User
        def my_function(%Us|)
      ]

      expected = ~q[
        alias Project.Structs.User
        def my_function(%User{$1})
      ]

      assert [completion] = complete(project, source)

      assert completion.kind == CompletionItemKind.struct()
      assert apply_completion(completion) == expected
    end

    test "should complete in an open block", %{project: project} do
      source = ~q[
        defmodule Example do
          def foo do
            %Project.Structs.Ac|
      ]

      assert [completion] = complete(project, source)
      assert completion.kind == CompletionItemKind.struct()
      assert apply_completion(completion) =~ "    %Project.Structs.Account{$1}"
    end

    test "should complete aliases in an open block", %{project: project} do
      source = ~q[
        defmodule Example do
          alias Project.Structs.Account
          def foo do
            %Ac|
      ]

      assert [completion] = complete(project, source)
      assert completion.kind == CompletionItemKind.struct()
      assert apply_completion(completion) =~ "    %Account{$1}"
    end

    test "should complete, but not add curlies for aliases after %", %{project: project} do
      source = ~q[
        alias Project.Structs.User
        def my_function(%Us|{})
      ]

      expected = ~q[
        alias Project.Structs.User
        def my_function(%User{})
      ]

      assert [completion] = complete(project, source)

      assert completion.kind == CompletionItemKind.struct()
      assert apply_completion(completion) == expected
    end

    if Version.match?(System.version(), ">= 1.15.0") do
      # The elixir sense upgrade caused these tests to fail.
      test "should complete module aliases after %", %{project: project} do
        source = ~q[
        defmodule TestModule do
        alias Project.Structs.User

        def my_function(%Us|)
      ]

        expected = ~q[
        defmodule TestModule do
        alias Project.Structs.User

        def my_function(%User{$1})
      ]

        assert [completion] = complete(project, source)

        assert completion.kind == CompletionItemKind.struct()
        assert apply_completion(completion) == expected
      end

      test "should complete, but not add curlies when last word not contains %", %{
        project: project
      } do
        source = ~q[
        defmodule TestModule do
        alias Project.Structs.User

        Us|
      ]

        assert [completion] = complete(project, source)
        assert completion.kind == CompletionItemKind.module()

        assert apply_completion(completion) == ~q[
        defmodule TestModule do
        alias Project.Structs.User

        User
      ]
      end
    end

    test "should complete non-aliased correctly", %{project: project} do
      source = ~q[
        def my_function(%Project.Structs.U|)
      ]

      expected = ~q[
        def my_function(%Project.Structs.User{$1})
      ]

      assert [completion] = complete(project, source)

      assert completion.kind == CompletionItemKind.struct()
      assert apply_completion(completion) == expected
    end

    test "does not add curlies if they're already present in a non-aliased reference", %{
      project: project
    } do
      source = ~q[
        def my_function(%Project.Structs.U|{})
      ]

      expected = ~q[
        def my_function(%Project.Structs.User{})
      ]

      assert [completion] = complete(project, source)
      assert completion.kind == CompletionItemKind.struct()
      assert apply_completion(completion) == expected
    end

    test "when using %, child structs are returned", %{project: project} do
      assert [account, order, order_line, user] =
               project
               |> complete("%Project.Structs.|", trigger_character: "%")
               |> Enum.sort_by(& &1.label)

      assert account.label == "Account"
      assert account.detail == "Project.Structs.Account"

      assert user.label == "User"
      assert user.detail == "Project.Structs.User"

      assert order.label == "Order"
      assert order.detail == "Project.Structs.Order"

      assert order_line.label == "Order...(1 more struct)"
      assert order_line.detail == "Project.Structs.Order."
    end

    test "when using % and child is not a struct, just `more` snippet is returned", %{
      project: project
    } do
      assert [more] = complete(project, "%Project.|", trigger_character: "%")
      assert more.label == "Structs...(4 more structs)"
      assert more.detail == "Project.Structs."
    end

    test "it should complete struct fields", %{project: project} do
      source = ~q[
        defmodule Fake do
          alias Project.Structs.User
          def my_function(%User{} = u) do
            u.|
          end
        end
      ]

      assert fields = complete(project, source)

      assert length(fields) == 3
      assert Enum.find(fields, &(&1.label == "first_name"))
      assert Enum.find(fields, &(&1.label == "last_name"))
      assert Enum.find(fields, &(&1.label == "email_address"))
    end

    test "it should complete module structs", %{project: project} do
      source = ~q{
        defmodule NewStruct do
          defstruct [:name, :value]

          def my_function(%__|)
      }

      expected = ~q<
        defmodule NewStruct do
          defstruct [:name, :value]

          def my_function(%__MODULE__{$1})
      >

      assert {:ok, completion} =
               project
               |> complete(source)
               |> fetch_completion(kind: CompletionItemKind.struct())

      assert apply_completion(completion) == expected
    end

    test "it should complete module structs after characters are typed", %{project: project} do
      source = ~q{
        defmodule NewStruct do
          defstruct [:name, :value]

          def my_function(%__MO|)
      }

      expected = ~q<
        defmodule NewStruct do
          defstruct [:name, :value]

          def my_function(%__MODULE__{$1})
      >

      assert {:ok, completion} =
               project
               |> complete(source)
               |> fetch_completion(kind: CompletionItemKind.struct())

      assert apply_completion(completion) == expected
    end

    test "it should complete module structs when completing module type", %{project: project} do
      source = ~q<
        defmodule NewStruct do
          defstruct [:name, :value]

          @type t :: %_|
      >

      expected = ~q<
        defmodule NewStruct do
          defstruct [:name, :value]

          @type t :: %__MODULE__{$1}
      >

      assert {:ok, completion} =
               project
               |> complete(source)
               |> fetch_completion(kind: CompletionItemKind.struct())

      assert apply_completion(completion) == expected
    end

    test "can be aliased", %{project: project} do
      assert [completion] = complete(project, "alias Project.Structs.A|")
      assert apply_completion(completion) == "alias Project.Structs.Account"
    end
  end
end
