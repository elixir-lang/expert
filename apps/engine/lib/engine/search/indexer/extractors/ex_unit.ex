defmodule Engine.Search.Indexer.Extractors.ExUnit do
  alias Engine.Analyzer
  alias Engine.Search.Indexer.Metadata
  alias Engine.Search.Indexer.Source.Reducer
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Formats
  alias Forge.Search.Indexer.Entry

  require Logger

  # setup block i.e. setup do... or setup arg do...
  def extract({setup_fn, _, args} = setup, %Reducer{} = reducer)
      when setup_fn in [:setup, :setup_all] and length(args) > 0 do
    {:ok, module} = Analyzer.current_module(reducer.analysis, Reducer.position(reducer))
    arity = arity_for(args)
    subject = Formats.mfa(module, setup_fn, arity)
    setup_type = :"ex_unit_#{setup_fn}"

    entry =
      case Metadata.location(setup) do
        {:block, _, _, _} ->
          block_entry(reducer, setup, setup_type, subject)

        {:expression, _} ->
          expression_entry(reducer, setup, setup_type, subject)
      end

    {:ok, entry}
  end

  # Test block test "test name" do ... or test "test name", arg do
  def extract({:test, _, [{_, _, [test_name]} | _] = args} = test, %Reducer{} = reducer)
      when is_binary(test_name) do
    {:ok, module} = Analyzer.current_module(reducer.analysis, Reducer.position(reducer))
    arity = arity_for(args)
    module_name = Formats.module(module)
    subject = "#{module_name}.[\"#{test_name}\"]/#{arity}"

    entry =
      case Metadata.location(test) do
        {:block, _, _, _} ->
          # a test with a body
          block_entry(reducer, test, :ex_unit_test, subject)

        {:expression, _} ->
          # a pending test
          expression_entry(reducer, test, :ex_unit_test, subject)
      end

    {:ok, entry}
  end

  # describe blocks
  def extract({:describe, _, [{_, _, [describe_name]} | _] = args} = test, %Reducer{} = reducer) do
    {:ok, module} = Analyzer.current_module(reducer.analysis, Reducer.position(reducer))
    arity = arity_for(args)
    module_name = Formats.module(module)
    subject = "#{module_name}[\"#{describe_name}\"]/#{arity}"

    entry = block_entry(reducer, test, :ex_unit_describe, subject)

    {:ok, entry}
  end

  def extract(_ign, _) do
    :ignored
  end

  defp expression_entry(%Reducer{} = reducer, ast, type, subject) do
    path = reducer.analysis.document.path
    block = Reducer.current_block(reducer)

    {:ok, module} = Analyzer.current_module(reducer.analysis, Reducer.position(reducer))
    app = Application.get_application(module)
    detail_range = detail_range(reducer.analysis, ast)

    Entry.definition(path, block, subject, type, detail_range, app)
  end

  defp block_entry(%Reducer{} = reducer, ast, type, subject) do
    path = reducer.analysis.document.path
    block = Reducer.current_block(reducer)

    {:ok, module} = Analyzer.current_module(reducer.analysis, Reducer.position(reducer))
    app = Application.get_application(module)
    detail_range = detail_range(reducer.analysis, ast)
    block_range = block_range(reducer.analysis, ast)
    Entry.block_definition(path, block, subject, type, block_range, detail_range, app)
  end

  defp block_range(%Analysis{} = analysis, ast) do
    case Ast.Range.fetch(ast, analysis.document) do
      {:ok, range} -> range
      _ -> nil
    end
  end

  defp detail_range(%Analysis{} = analysis, ast) do
    case Metadata.location(ast) do
      {:block, {start_line, start_column}, {do_line, do_column}, _} ->
        Range.new(
          Position.new(analysis.document, start_line, start_column),
          Position.new(analysis.document, do_line, do_column + 2)
        )

      {:expression, {start_line, start_column}} ->
        %{end: [line: end_line, column: end_column]} = Sourceror.get_range(ast)

        Range.new(
          Position.new(analysis.document, start_line, start_column),
          Position.new(analysis.document, end_line, end_column)
        )
    end
  end

  defp arity_for([{:__block__, _meta, labels}]) do
    length(labels)
  end

  defp arity_for(args) when is_list(args) do
    length(args)
  end

  defp arity_for(_), do: 0
end
