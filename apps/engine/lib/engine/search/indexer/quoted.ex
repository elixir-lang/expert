defmodule Engine.Search.Indexer.Quoted do
  alias Engine.Search.Indexer.Source.Reducer
  alias Forge.Ast.Analysis
  alias Forge.ProcessCache

  require ProcessCache

  def index_with_cleanup(%Analysis{} = analysis) do
    ProcessCache.with_cleanup do
      index(analysis)
    end
  end

  def index(analysis, extractors \\ nil)

  def index(%Analysis{valid?: true} = analysis, extractors) do
    {_, reducer} =
      Macro.prewalk(analysis.ast, Reducer.new(analysis, extractors), fn elem, reducer ->
        {reducer, elem} = Reducer.reduce(reducer, elem)
        {elem, reducer}
      end)

    {:ok, Reducer.entries(reducer)}
  end

  def index(%Analysis{valid?: false}, _extractors) do
    {:ok, []}
  end
end
