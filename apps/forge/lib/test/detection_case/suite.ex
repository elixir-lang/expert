defmodule Forge.Test.DetectionCase.Suite do
  @moduledoc """
  Defines a test suite for the detection case tests.
  """
  import Forge.Test.CodeSigil

  @doc """
  Returns a list of tuples where:

  The first element is the path of the suite. Test cases can select and
  skip parts of the suite based on the path

  The second element is the code, defined via the code sigil. The code can contain
  multiple ranges, defined with the `«` and `»` characters. Ranges define the areas
  of the code that contain the part of the code that is expected to be detected by
  the recognizer with the same name as the first element of the list.
  """

  def suite do
    [
      alias: [
        single: ~q(alias F«oo»),
        multiple: ~q(
             alias M«yModule.{
               First,
               Second,
               Third»
             }
        ),
        as: ~q[alias M«yModule.Submodule, as: Alias»],
        # Note: we need the token after the alias for the test, since
        # we can't place a range on an empty space
        multiple_on_one_line: ~q[alias F«oo.{Bar, Baz, Quux»};3 ]
      ],
      bitstring: [
        one_line: ~q[<<«foo::integer, bar::binary»>>],
        multi_line: ~q[
           <<«foo::integer,
           bar::binary-size(6)
           »>>
           ]
      ],
      callbacks: [
        callback: [
          zero_arg: "@«callback my_cb() :: boolean()»",
          one_arg: "@«callback my_cb(foo :: integer) :: String.t()»",
          multiple_args: "@«callback my_cb(foo :: integer, bar:: String.t()) :: [pos_integer()]»",
          multiple_line: """
          @«callback my_cb(
              foo :: String.t(),
              bar :: pos_integer()) :: pos_integer()»
          """
        ],
        macrocallback: [
          zero_arg: "@«macrocallback my_cb() :: boolean()»",
          one_arg: "@«macrocallback my_cb(foo :: integer) :: String.t()»",
          multiple_args:
            "@«macrocallback my_cb(foo :: integer, bar:: String.t()) :: [pos_integer()]»",
          multiple_line: """
          @«macrocallback my_cb(
              foo :: String.t(),
              bar :: pos_integer()) :: pos_integer()»
          """
        ]
      ],
      comment: [
        start_of_line: "«# IO.puts»",
        end_of_line: "IO.puts(thing) «# IO.puts»"
      ],
      doc: [
        empty: ~S[@«doc ""»],
        false: "@«doc false»",
        single_line: ~S[@«doc "this is my doc»"],
        multi_line: ~S[@«doc """
        This is the doc
        """»
        ]
      ],
      function_capture: [
        local_arity: ~q[&«my_fun/1»],
        local_argument: ~q[&«my_fun(arg, &1)»],
        remote_arity: ~q[&«Remote.my_fun/1»],
        remote_argument: ~q[&«Remote.my_fun(arg, &1)»]
      ],
      import: [
        single: ~q(import« MyModule»),
        chain: ~q(import« MyModule.SubModule»),
        only: [
          single_line: ~q(import« OtherModule, only: [something: 3, other_thing: 2]»),
          multi_line: ~q(import« OtherModule, only: »[
                  something: 3,
                  other_thing: 2
                ])
        ],
        except: [
          single_line: ~q(import« OtherModule, except: [something: 3, other_thing: 2]»),
          multi_line: ~q(import« OtherModule, except: »[
                   something: 3,
                   other_thing: 2
                 ])
        ]
      ],
      keyword: [
        single_line:
          ~q(«string: "value", atom: :value2, int: 6, float: 2.0, list: [1, 2], tuple: {3, 4}»),
        multi_line: ~q(
          [«
           string: "value",
           atom: :value2,
           int: 6,
           float: 2.0,
           list: [1, 2],
           tuple: {3, 4}
           »])
      ],
      map: [
        single_line:
          ~q(%{«string: "value", atom: :value2, int: 6 float: 2.0, list: [1, 2], tuple: {3, 4}}»)
      ],
      module_doc: [
        empty: ~S[@«moduledoc ""»],
        false: "@«moduledoc false»",
        single_line: ~S[@«moduledoc "this is my moduledoc»"],
        multi_line: ~S[@«moduledoc """
        This is the moduledoc
        """»
        ]
      ],
      module_attribute: [
        single_line: "@«attr 45»",
        multi_line_pipe: """
        @«attr other_thing»
          |> «Enum.shuffle()»
          |> «Enum.max()»
        """,
        multi_line_list: """
        @«attrs [»
          «:foo»,
          «:bar»,
          «:baz»
        ]
        """
      ],
      pipe: [
        one_line: ~q[foo |> «bar»() |> «RemoteCall.fun»() |> «:remote_erlang.call»()],
        multi_line: ~q[
            document
            |> «local_call»()
            |> «RemoteModule.call»()
            |> «:remote_erlang.call»()
          ]
      ],
      require: [
        single: ~q(require« MyModule»),
        chain: ~q(require« MyModule.Submodule»)
      ],
      spec: [
        simple_function: ~q{@spec« function_name(String.t) :: any()»},
        multi_line: ~q{
            @spec «on_multiple_lines :: integer()»
            | «String.t()»
            | «something()»
          },
        or_type: ~q{@spec« my_func() :: :yours | :mine | :the_truth»}
      ],
      struct_field_key: [
        simple: ~q[%User{«foo:» 3,« bar:» 8}]
      ],
      struct_field_value: [
        single_line: ~q[%User{field_name:« 3», next_name:« :atom»}]
      ],
      struct_fields: [
        one_line: [
          empty: ~q[%User{«»}],
          simple: ~q[%User{«field_name: 3, other_name: 9»}]
        ],
        multi_line: [
          simple: ~q[
            %Struct{«
                  amount: 1,
                  kind: :tomatoes»
                 }
          ]
        ]
      ],
      strings: [
        literal: ~q["«this is a string»"],
        interpolation: [
          variable: ~S["«before »#{interp}« after»"],
          math: ~S["«before »#{3 + 1}« after»"],
          function_call: ~S["«before »#{my_fun(arg)}« after»"],
          multiple: ~S["«before »#{first}« middle »#{second}« after»"]
        ],
        heredocs: [
          simple: ~S[
        """
        «This is in the heredoc
        It's multiple lines»
        """
        ],
          interpolation: ~S[
          """
          «This is the heredoc
          #{something} is interpolated»
          """
          ]
        ],
        sigils: [
          s: [
            single_line: ~S[
         ~s/«this is a string»/
          ],
            multi_line: ~S[
             ~s/«
              this is a string
              that spans
              many lines
            »/
            ]
          ],
          S: [
            single_line: ~S[
         ~S/«this is a string»/
          ],
            multi_line: ~S[
           ~S/«
            this is a string
            that spans
            many lines
          »/
          ]
          ]
        ]
      ],
      struct_reference: [
        single_line: ~q(%U«ser»{#{keys_and_values()}}),
        nested: ~q[%U«ser»{account: %A«ccount»{#{keys_and_values()}}}]
      ],
      type: [
        private: ~q[@typep« my_type :: integer()»],
        opaque: ~q[@opaque« opaque :: integer()»],
        single_line: [
          simple: ~q[@type« my_type :: integer()»],
          composite: ~q[@type« my_type :: :foo | :bar | :baz»]
        ],
        multi_line: [
          composite: ~q[
             @type« multi_line ::»
             «integer()»
             |« String.t()»
             |« Something.t()»
           ]
        ]
      ],
      use: [
        simple: ~q(use« SomeModule»),
        params: [
          single_line: ~q(use« SomeModule, param: 3, other_param: :doggy»),
          multi_line: ~q(
             use «SomeModule, »[
               with: :features,
               that_are: :great
             ]
           )
        ]
      ]
    ]
  end

  def get do
    flatten(suite())
  end

  defp flatten(keyword) do
    keyword
    |> do_flatten([], [])
    |> Enum.map(fn {path, value} -> {Enum.reverse(path), value} end)
  end

  defp do_flatten(keyword, prefix, acc) do
    Enum.reduce(keyword, acc, fn
      {k, v}, acc when is_list(v) ->
        do_flatten(v, [k | prefix], acc)

      {k, v}, acc ->
        [{[k | prefix], v} | acc]
    end)
  end

  defp list_literal do
    ~q([:atom, 1, 2.0, "string", %{a: 1, b: 2}, [1, 2, 3], {1, 2}])
  end

  defp map_literal do
    ~q(%{foo: 3, bar: 6})
  end

  defp keyword_literal do
    ~q([key_1: 3, key_2: #{list_literal()}])
  end

  defp tuple_litral do
    ~q({:atom, 1, 2.0, "string", %{a: 1, b: 2}, [1, 2, 3], {1, 2}})
  end

  defp keys_and_values do
    ~q(string: "value", atom: :value2, int: 6 float: 2.0, keyword: #{keyword_literal()} map: #{map_literal()}, list: #{list_literal()}, tuple: #{tuple_litral()})
  end
end
