defmodule Forge.Test.DetectionCase do
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Tokens
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Test.DetectionCase.Suite
  alias Forge.Test.Variations

  import Forge.Test.RangeSupport
  import ExUnit.Assertions
  use ExUnit.CaseTemplate

  using(args) do
    context = Keyword.fetch!(args, :for)
    assertion_query = Keyword.fetch!(args, :assertions)
    variations = Keyword.get(args, :variations, []) ++ [:nothing]
    # sometimes one type of thing can be found in another (for example, a struct reference is
    # found in a struct field case), so we don't want to build a refutation
    # for that thing. `skip` allows us to remove certain cases from refutes.
    skip = Keyword.get(args, :skip, [])

    {assertions, refutes} = Enum.split_with(Suite.get(), &matches?(&1, assertion_query))

    if Enum.empty?(assertions) do
      query =
        assertion_query
        |> Macro.expand(__CALLER__)
        |> Macro.to_string()

      flunk("No assertions matched the query #{query}")
    end

    refutes = Enum.reject(refutes, &matches?(&1, skip))
    assertions = build_assertion_cases(context, assertions, variations)
    refutations = build_refutation_cases(context, refutes, variations)

    quote location: :keep do
      @context unquote(context)
      alias Forge.Test.DetectionCase

      import Forge.Test.CodeSigil

      import unquote(__MODULE__),
        only: [
          assert_detected: 2,
          refute_detected: 2
        ]

      unquote_splicing(assertions)
      unquote_splicing(refutations)

      def assert_detected(code) do
        assert_detected @context, code
      end

      def refute_detected(code) do
        refute_detected @context, code
      end
    end
  end

  def refute_detected(context, code) do
    document = Document.new("file:///file.ex", code, 1)
    analysis = Ast.analyze(document)

    for position <- position_stream(document) do
      try do
        refute context.detected?(analysis, position)
      rescue
        e in ExUnit.AssertionError ->
          flunk(error_for(document, position, context, e))
      end
    end
  end

  def assert_detected(context, code) do
    {ranges, code} = pop_all_ranges(code)

    document = Document.new("file:///file.ex", code, 1)
    analysis = Ast.analyze(document)
    assert_contexts_in_range(analysis, context, ranges)
  end

  defp includes?(%Range{} = range, %Position{} = position) do
    cond do
      range.start.line == position.line and range.end.line == position.line ->
        position.character >= range.start.character and
          position.character <= range.end.character

      range.start.line == position.line ->
        position.character >= range.start.character

      range.end.line == position.line ->
        position.character <= range.end.character

      true ->
        position.line > range.start.line and position.line < range.end.line
    end
  end

  defp matches?({type, _}, assertions) do
    Enum.any?(assertions, &wildcard_matches?(&1, type))
  end

  defp wildcard_matches?(wildcard, type) do
    wildcard
    |> Enum.zip(type)
    |> Enum.reduce_while(true, fn
      {same, same}, _ ->
        {:cont, true}

      {:*, _}, _ ->
        {:halt, true}

      {_, _}, _ ->
        {:halt, false}
    end)
  end

  defp build_assertion_cases(context, assertions, variations) do
    for {type, test} <- assertions,
        variation <- variations do
      build_assertion_variation(context, type, variation, test)
    end
  end

  defp build_assertion_variation(context, type, variation, test) do
    assertion_text = Variations.wrap_with(variation, test)
    test_name = type_to_name(type, variation)

    quote generated: true do
      test unquote(test_name) do
        assert_detected unquote(context), unquote(assertion_text)
      end
    end
  end

  defp assert_contexts_in_range(%Analysis{} = analysis, context, ranges) do
    positions_by_range =
      analysis.document
      |> position_stream()
      |> Enum.group_by(fn position -> Enum.find(ranges, &includes?(&1, position)) end)

    for {range, positions} <- positions_by_range,
        position <- positions do
      try do
        if range do
          assert context.detected?(analysis, position)
        else
          refute context.detected?(analysis, position)
        end
      rescue
        e in ExUnit.AssertionError ->
          analysis.document
          |> error_for(position, context, e)
          |> ExUnit.Assertions.flunk()
      end
    end
  end

  defp build_refutation_cases(context, assertions, variations) do
    for {type, test} <- assertions,
        variation <- variations do
      build_refutation_variation(context, type, variation, test)
    end
  end

  defp build_refutation_variation(context, type, variation, test) do
    {_range, refutation_text} =
      variation
      |> Variations.wrap_with(test)
      |> pop_range()

    test_name = type_to_name(type, variation)

    quote generated: true do
      test unquote(test_name) do
        refute_detected unquote(context), unquote(refutation_text)
      end
    end
  end

  defp error_for(%Document{} = doc, %Position{} = pos, context, assertion_error) do
    message = message_for_assertion_type(assertion_error, context, pos)

    test_text =
      doc
      |> insert_cursor(pos)
      |> Document.to_string()

    [
      IO.ANSI.red(),
      message,
      IO.ANSI.reset(),
      "\n",
      "document:",
      "\n\n",
      test_text,
      "\n\n"
    ]
    |> IO.ANSI.format()
    |> IO.iodata_to_binary()
  end

  defp message_for_assertion_type(%ExUnit.AssertionError{} = error, context, position) do
    context = context |> Module.split() |> List.last()

    case assertion_type(error.expr) do
      :assert ->
        "The cursor at {#{position.line}, #{position.character}} should have been detected as a #{context}, but it wasn't."

      :refute ->
        "The cursor at {#{position.line}, #{position.character}} was detected as #{context}, but it shouldn't have been"
    end
  end

  defp assertion_type({type, _, _}) do
    case Atom.to_string(type) do
      "assert" <> _ -> :assert
      _ -> :refute
    end
  end

  defp insert_cursor(%Document{} = document, %Position{} = position) do
    cursor =
      [
        IO.ANSI.bright(),
        IO.ANSI.light_red(),
        "|",
        IO.ANSI.reset()
      ]
      |> IO.ANSI.format()
      |> IO.iodata_to_binary()

    range = Range.new(position, position)
    edit = Document.Edit.new(cursor, range)
    {:ok, document} = Document.apply_content_changes(document, document.version + 1, [edit])

    document
  end

  defp type_to_name(type, variation) do
    words = fn atom ->
      atom
      |> Atom.to_string()
      |> String.split("_")
      |> Enum.join(" ")
    end

    base_name = Enum.map_join(type, ", ", words)

    variation =
      if variation == :nothing do
        ""
      else
        "(inside #{words.(variation)})"
      end

    "#{base_name} #{variation}"
  end

  def position_stream(%Document{} = document) do
    line_count = Document.size(document)

    init_fn = fn ->
      1
    end

    next_fn = fn
      line_number when line_number <= line_count ->
        case Document.fetch_text_at(document, line_number) do
          {:ok, line_text} ->
            token_positions =
              document
              |> Tokens.prefix_stream(
                Position.new(document, line_number, String.length(line_text) + 1)
              )
              |> Stream.filter(fn
                {_token, _, {^line_number, _character}} ->
                  true

                _ ->
                  false
              end)
              |> Enum.reduce(
                [],
                fn
                  {:string, contents, position}, acc ->
                    string_literal_positions(document, contents, position) ++ acc

                  {:interpolated_string, interpolations, _}, acc ->
                    interpolation_positions(document, interpolations) ++ acc

                  {_token_type, _token, {_line, character}}, acc ->
                    pos = Position.new(document, line_number, character)
                    [pos | acc]
                end
              )

            {token_positions, line_number + 1}
        end

      _ ->
        {:halt, :ok}
    end

    finalize = fn _ -> :ok end

    Stream.resource(init_fn, next_fn, finalize)
  end

  defp string_literal_positions(%Document{} = document, string_contents, {line, column}) do
    # add two for the quotes
    string_length = String.length(string_contents) + 2
    before_pos = Position.new(document, line, column + 1)
    after_pos = Position.new(document, line, column + string_length)

    [after_pos, before_pos]
  end

  defp interpolation_positions(%Document{} = document, interpolations) do
    interpolations
    |> Enum.flat_map(fn {_, _, {{start_line, start_col}, {_end_line, end_col}}} ->
      in_between_positions =
        Enum.map(start_col..end_col, fn column ->
          Position.new(document, start_line, column)
        end)

      start_pos = Position.new(document, start_line, start_col)

      [start_pos | in_between_positions]
    end)
    |> Enum.uniq()
  end
end
