defmodule Expert.CodeIntelligence.Completion.Translations.CallbackTest do
  use Expert.Test.Expert.CompletionCase

  alias GenLSP.Enumerations.CompletionItemKind

  describe "callback completions" do
    test "suggest callbacks", %{project: project} do
      source = ~q[
        defmodule MyServer do
          use GenServer
          def handle_inf|
        end
      ]

      {:ok, completion} =
        project
        |> complete(source)
        |> fetch_completion(kind: CompletionItemKind.interface())

      assert apply_completion(completion) =~
               "@impl true\ndef handle_info(${1:msg}, ${2:state}) do"
    end

    test "do not add parens if they're already present", %{project: project} do
      source = ~q[
        defmodule MyServer do
          use GenServer
          def handle_inf|(msg, state)
        end
      ]

      {:ok, completion} =
        project
        |> complete(source)
        |> fetch_completion(kind: CompletionItemKind.interface())

      assert apply_completion(completion) =~
               "@impl true\ndef handle_info(${1:msg}, ${2:state}) do"
    end

    test "does not add second @impl if one is already present", %{project: project} do
      source = ~q[
        defmodule MyServer do
          use GenServer
          @impl true
          def handle_inf|
        end
      ]

      {:ok, completion} =
        project
        |> complete(source)
        |> fetch_completion(kind: CompletionItemKind.interface())

      assert apply_completion(completion) == """
             defmodule MyServer do
               use GenServer
               @impl true
               def handle_info(${1:msg}, ${2:state}) do
               $0
             end
             end
             """
    end
  end
end
