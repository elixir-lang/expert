defmodule Engine.Search.Indexer.Extractors.StructDefinition do
  alias Engine.Analyzer
  alias Engine.Search.Indexer.Source.Reducer
  alias Forge.Ast
  alias Forge.Search.Indexer.Entry

  def extract({:defstruct, _, [_fields]} = definition, %Reducer{} = reducer) do
    document = reducer.analysis.document
    block = Reducer.current_block(reducer)

    case Analyzer.current_module(reducer.analysis, Reducer.position(reducer)) do
      {:ok, current_module} ->
        range = Ast.Range.fetch!(definition, document)

        entry =
          Entry.definition(
            document.path,
            block,
            current_module,
            :struct,
            range,
            Application.get_application(current_module)
          )

        {:ok, entry}

      _ ->
        :ignored
    end
  end

  def extract(_, _) do
    :ignored
  end
end
