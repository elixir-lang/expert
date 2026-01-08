defmodule Expert.Provider.Handlers.FoldingRangeTest do
  use ExUnit.Case
  use Forge.Test.DocumentSupport

  alias Expert.Provider.Handlers.FoldingRange

  def to_document(text) do
    Forge.Document.new("file://elixir.ex", text, 1)
  end

  describe "indentation" do
    setup [:fold_via_indentation]

    @tag text: """
         defmodule A do    # 0
           def hello() do  # 1
             :world        # 2
           end             # 3
         end               # 4
         """
    test "basic test", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{0, 3}, {1, 2}], text)
    end

    @tag text: """
         defmodule A do    # 0
           def hello() do  # 1
             # world       # 2
             if true do    # 3
               :world      # 4
             end           # 5
           end             # 6
         end               # 7
         """
    test "consecutive matching levels", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{0, 6}, {1, 5}, {3, 4}], text)
    end

    @tag text: """
         defmodule A do                                         # 0
           def f(%{"key" => value} = map) do                    # 1
             case NaiveDateTime.from_iso8601(value) do          # 2
               {:ok, ndt} ->                                    # 3
                 dt =                                           # 4
                   ndt                                          # 5
                   |> DateTime.from_naive!("Etc/UTC")           # 6
                   |> Map.put(:microsecond, {0, 6})             # 7

                 %{map | "key" => dt}                           # 9

               e ->                                             # 11
                 Logger.warning(\"\"\"
                 Could not use data map from #\{inspect(value)\}  # 13
                 #\{inspect(e)\}                                  # 14
                 \"\"\")

                 :could_not_parse_value                         # 17
             end                                                # 18
           end                                                  # 19
         end                                                    # 20
         """
    test "complicated function", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      expected = [{0, 19}, {1, 18}, {2, 17}, {3, 9}, {4, 7}, {11, 17}]
      assert compare_condensed_ranges(ranges, expected, text)
    end

    @tag text: """
         defmodule A do                      # 0
           def get_info(args) do             # 1
             org =                           # 2
               args                          # 3
               |> Ecto.assoc(:organization)  # 4
               |> Repo.one!()                # 5

             user =                          # 7
               org                           # 8
               |> Organization.user!()       # 9

             {:ok, %{org: org, user: user}}  # 11
           end                               # 12
         end                                 # 13
         """
    test "different complicated function", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{0, 12}, {1, 11}, {2, 5}, {7, 9}], text)
    end

    defp fold_via_indentation(%{text: text} = context) do
      ranges_result =
        text
        |> to_document()
        |> FoldingRange.document_to_input()
        |> FoldingRange.Indentation.provide_ranges()

      {:ok, Map.put(context, :ranges_result, ranges_result)}
    end
  end

  describe "token pairs" do
    setup [:fold_via_token_pairs]

    @tag text: """
         defmodule A do    # 0
           def hello() do  # 1
             :world        # 2
           end             # 3
         end               # 4
         """
    test "basic test", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{0, 3}, {1, 2}], text)
    end

    @tag text: """
         defmodule A do    # 0
           def hello() do  # 1
             :world        # 2
               end         # 3
                 end       # 4
         """
    test "unusual indentation", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{0, 3}, {1, 2}], text)
    end

    @tag text: """
         defmodule A do    # 0
           def hello() do  # 1
             if true do    # 2
               :hello      # 3
             else          # 4
               :error      # 5
             end           # 6
           end             # 7
         end               # 8
         """
    test "if-do-else-end", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{0, 7}, {1, 6}, {2, 3}, {4, 5}], text)
    end

    @tag text: """
         defmodule A do             # 0
           def hello() do           # 1
             try do                 # 2
               :hello               # 3
             rescue                 # 4
               ArgumentError ->     # 5
                 IO.puts("rescue")  # 6
             catch                  # 7
               value ->             # 8
                 IO.puts("catch")   # 9
             else                   # 10
               value ->             # 11
                 IO.puts("else")    # 12
             after                  # 13
               IO.puts("after")     # 14
             end                    # 15
           end                      # 16
         end                        # 17
         """
    test "try block", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      expected = [{0, 16}, {1, 15}, {2, 3}, {4, 6}, {7, 9}, {10, 12}, {13, 14}]
      assert compare_condensed_ranges(ranges, expected, text)
    end

    @tag text: """
         defmodule A do     # 0
           def hello() do   # 1
             a = 20         # 2

             case a do      # 4
               20 ->        # 5
                :ok         # 6

               _ ->         # 8
                :error      # 9
             end            # 10
           end              # 11
         end                # 12
         """
    test "1 defmodule, 1 def, 1 case", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{0, 11}, {1, 10}, {4, 9}], text)
    end

    @tag text: """
         defmodule A do    # 0
           def hello() do  # 1
             <<0>>         # 2
             <<            # 3
               1, 2, 3,    # 4
               4, 5, 6     # 5
             >>            # 6
           end             # 7
         end               # 8
         """
    test "binaries", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{0, 7}, {1, 6}, {3, 5}], text)
    end

    @tag text: """
         defmodule A do                   # 0
           @moduledoc "This is module A"  # 1
         end                              # 2

         defmodule B do                   # 4
           @moduledoc "This is module B"  # 5
         end                              # 6
         """
    test "2 defmodules in the top-level of file", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{0, 1}, {4, 5}], text)
    end

    @tag text: """
         defmodule A do                       # 0
           def compare_and_hello(list) do     # 1
             assert list == [                 # 2
                      %{"a" => 1, "b" => 2},  # 3
                      %{"a" => 3, "b" => 4},  # 4
                    ]                         # 5

             :world                           # 7
           end                                # 8
         end                                  # 9
         """
    test "1 defmodule, 1 def, 1 list", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{0, 8}, {1, 7}, {2, 4}], text)
    end

    @tag text: """
         defmodule A do                                         # 0
           def f(%{"key" => value} = map) do                    # 1
             case NaiveDateTime.from_iso8601(value) do          # 2
               {:ok, ndt} ->                                    # 3
                 dt =                                           # 4
                   ndt                                          # 5
                   |> DateTime.from_naive!("Etc/UTC")           # 6
                   |> Map.put(:microsecond, {0, 6})             # 7

                 %{map | "key" => dt}                           # 9

               e ->                                             # 11
                 Logger.warning(\"\"\"
                 Could not use data map from #\{inspect(value)\}  # 13
                 #\{inspect(e)\}                                  # 14
                 \"\"\")

                 :could_not_parse_value                         # 17
             end                                                # 18
           end                                                  # 19
         end                                                    # 20
         """
    test "complicated function", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{0, 19}, {1, 18}, {2, 17}, {12, 14}], text)
    end

    defp fold_via_token_pairs(%{text: text} = context) do
      ranges_result =
        text
        |> to_document()
        |> FoldingRange.document_to_input()
        |> FoldingRange.TokenPair.provide_ranges()

      {:ok, Map.put(context, :ranges_result, ranges_result)}
    end
  end

  describe "special tokens" do
    setup [:fold_via_special_tokens]

    @tag text: """
         defmodule A do       # 0
          @moduledoc \"\"\"
          @moduledoc heredoc  # 2
          \"\"\"

          @doc \"\"\"
          @doc heredoc        # 6
          \"\"\"
           def hello() do     # 8
             \"\"\"
             regular heredoc  # 10
             \"\"\"
           end                # 12
         end                  # 13
         """
    test "@moduledoc, @doc, and stand-alone heredocs", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      expected = [{1, 2, "comment"}, {5, 6, "comment"}, {9, 10, "region"}]
      assert compare_condensed_ranges(ranges, expected, text)
    end

    @tag text: """
         defmodule A do        # 0
           def hello() do      # 1
             "
             regular string    # 3
             "
             '
             charlist string   # 6
             '
             \"\"\"
             regular heredoc   # 9
             \"\"\"
             '''
             charlist heredoc  # 12
             '''
           end                 # 14
         end                   # 15
         """
    test "charlist heredocs", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{2, 3}, {5, 6}, {8, 9}, {11, 12}], text)
    end

    @tag text: """
         defmodule A do    # 0
           def hello() do  # 1
             ~r/
               hello       # 3
             /
             ~r|
               hello       # 6
             |
             ~r"
               hello       # 9
             "
             ~r'
               hello       # 12
             '
             ~r(
               hello       # 15
               )
             ~r[
               hello       # 18
             ]
             ~r{
               hello       # 21
             }
             ~r<
               hello       # 24
             >
           end             # 26
         end               # 27
         """
    test "sigil delimiters", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      expected = [{2, 3}, {5, 6}, {8, 9}, {11, 12}, {14, 15}, {17, 18}, {20, 21}, {23, 24}]
      assert compare_condensed_ranges(ranges, expected, text)
    end

    @tag text: """
         defmodule A do          # 0
           @moduledoc ~S\"\"\"
           sigil @moduledoc      # 2
           \"\"\"

           @doc ~S\"\"\"
           sigil @doc            # 6
           \"\"\"
           def hello() do        # 8
             :world              # 9
           end                   # 10
         end                     # 11
         """
    test "@doc with ~S sigil", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{1, 2, "comment"}, {5, 6, "comment"}], text)
    end

    defp fold_via_special_tokens(%{text: text} = context) do
      ranges_result =
        text
        |> to_document()
        |> FoldingRange.document_to_input()
        |> FoldingRange.SpecialToken.provide_ranges()

      {:ok, Map.put(context, :ranges_result, ranges_result)}
    end
  end

  describe "comment blocks" do
    setup [:fold_via_comment_blocks]

    @tag text: """
         defmodule A do                 # 0
           def hello() do               # 1
             # single comment           # 2
             do_hello()                 # 3
           end                          # 4
         end                            # 5
         """
    test "no single line comment blocks", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [], text)
    end

    @tag text: """
         defmodule A do                 # 0
           def hello() do               # 1
             do_hello()                 # 2
           end                          # 3

           # comment block 0            # 5
           # comment block 1            # 6
           # comment block 2            # 7
           defp do_hello(), do: :world  # 8
         end                            # 9
         """
    test "@moduledoc, @doc, and stand-alone heredocs", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      assert compare_condensed_ranges(ranges, [{5, 7}], text)
    end

    defp fold_via_comment_blocks(%{text: text} = context) do
      ranges_result =
        text
        |> to_document()
        |> FoldingRange.document_to_input()
        |> FoldingRange.CommentBlock.provide_ranges()

      {:ok, Map.put(context, :ranges_result, ranges_result)}
    end
  end

  describe "end to end" do
    setup [:fold_text]

    @tag text: """
         defmodule A do                                         # 0
           @moduledoc ~S\"\"\"
           I'm a @moduledoc heredoc.                            # 2
           \"\"\"

           def f(%{"key" => value} = map) do                    # 5
             # comment block 0                                  # 6
             # comment block 1                                  # 7
             case NaiveDateTime.from_iso8601(value) do          # 8
               {:ok, ndt} ->                                    # 9
                 dt =                                           # 10
                   ndt                                          # 11
                   |> DateTime.from_naive!("Etc/UTC")           # 12
                   |> Map.put(:microsecond, {0, 6})             # 13

                 %{map | "key" => dt}                           # 15

               e ->                                             # 17
                 Logger.warning(\"\"\"
                 Could not use data map from #\{inspect(value)\}  # 19
                 #\{inspect(e)\}                                  # 20
                 \"\"\")

                 :could_not_parse_value                         # 23
             end                                                # 24
           end                                                  # 25
         end                                                    # 26
         """
    test "complicated function", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result

      expected = [
        {0, 25},
        {1, 2},
        {5, 24},
        {6, 7},
        {8, 23},
        {9, 15},
        {10, 13},
        {17, 23},
        {18, 20}
      ]

      assert compare_condensed_ranges(ranges, expected, text)
    end

    @tag text: """
         defmodule A do
           @doc false
           def init(_) do
             IO.puts("Hello World!")
             {:ok, []}
           end
         end
         """
    test "@doc false does not create a folding range", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      expected = [{0, 5, "region"}, {2, 4, "region"}]
      assert compare_condensed_ranges(ranges, expected, text)
    end

    @tag text: """
         defmodule A do
           @typedoc false
           @type t :: %{}

           def init(_) do
             IO.puts("Hello World!")
             {:ok, []}
           end
         end
         """
    test "@typedoc example", %{ranges_result: ranges_result, text: text} do
      assert {:ok, ranges} = ranges_result
      expected = [{0, 7, "region"}, {4, 6, "region"}]
      assert compare_condensed_ranges(ranges, expected, text)
    end

    @tag text: """
         defmodule A do
           @moduledoc false

           def init(_) do
             IO.puts("Hello World!")
             {:ok, []}
           end
         end
         """
    test "@moduledoc false does not create a folding range", %{
      ranges_result: ranges_result,
      text: text
    } do
      assert {:ok, ranges} = ranges_result
      expected = [{0, 6, "region"}, {3, 5, "region"}]
      assert compare_condensed_ranges(ranges, expected, text)
    end

    defp fold_text(%{text: text} = context) do
      start_supervised(Forge.Document.Store)

      uri = "file:///test.ex"

      :ok = Forge.Document.Store.open(uri, text, 1)

      request = %GenLSP.Requests.TextDocumentFoldingRange{
        id: 1,
        params: %GenLSP.Structures.FoldingRangeParams{
          text_document: %GenLSP.Structures.TextDocumentIdentifier{
            uri: uri
          }
        }
      }

      ranges_result = FoldingRange.handle(request, %Expert.Configuration{})
      {:ok, Map.put(context, :ranges_result, ranges_result)}
    end
  end

  defp compare_condensed_ranges(result, expected_condensed, text) do
    result_condensed =
      result
      |> Enum.map(fn
        %GenLSP.Structures.FoldingRange{start_line: start_line, end_line: end_line, kind: kind} ->
          {start_line, end_line, kind}

        %GenLSP.Structures.FoldingRange{start_line: start_line, end_line: end_line} ->
          {start_line, end_line, :any}
      end)
      |> Enum.sort()

    expected_condensed =
      expected_condensed
      |> Enum.map(fn
        {start_line, end_line, kind} ->
          {start_line, end_line, kind}

        {start_line, end_line} ->
          {start_line, end_line, :any}
      end)
      |> Enum.sort()

    {result_condensed, expected_condensed} =
      Enum.zip(result_condensed, expected_condensed)
      |> Enum.map(fn
        {{rs, re, rk}, {es, ee, ek}} when rk == :any or ek == :any ->
          {{rs, re, :any}, {es, ee, :any}}

        otherwise ->
          otherwise
      end)
      |> Enum.unzip()

    if result_condensed != expected_condensed do
      visualize_folding(text, result_condensed)
    end

    assert result_condensed == expected_condensed
  end

  def visualize_folding(nil, _), do: :ok

  def visualize_folding(text, result_condensed) do
    lines =
      String.split(text, "\n")
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        String.pad_leading(to_string(index), 2, " ") <> ": " <> line
      end)

    result_condensed
    |> Enum.map(fn {line_start, line_end, descriptor} ->
      out =
        Enum.slice(lines, line_start, line_end - line_start + 2)
        |> Enum.join("\n")

      IO.puts("Folding lines #{line_start}, #{line_end} (#{descriptor}):")
      IO.puts(out)
      IO.puts("\n")
    end)
  end
end
