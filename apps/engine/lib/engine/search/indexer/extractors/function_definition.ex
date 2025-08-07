defmodule Engine.Search.Indexer.Extractors.FunctionDefinition do
  alias Engine.Analyzer
  alias Engine.Search.Indexer.Source.Reducer
  alias Engine.Search.Subject
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Search.Indexer.Entry

  @function_definitions [:def, :defp]

  def extract({definition, _, [{fn_name, _, args} = def_ast, body]} = ast, %Reducer{} = reducer)
      when is_atom(fn_name) and definition in @function_definitions do
    with {:ok, detail_range} <- Ast.Range.fetch(def_ast, reducer.analysis.document),
         {:ok, module} <- Analyzer.current_module(reducer.analysis, detail_range.start),
         {fun_name, arity} when is_atom(fun_name) <- fun_name_and_arity(def_ast) do
      entry =
        Entry.block_definition(
          reducer.analysis.document.path,
          Reducer.current_block(reducer),
          Subject.mfa(module, fun_name, arity),
          type(definition),
          block_range(reducer.analysis, ast),
          detail_range,
          Application.get_application(module)
        )

      {:ok, entry, [args, body]}
    else
      _ ->
        :ignored
    end
  end

  def extract({:defdelegate, _, [call, _]} = node, %Reducer{} = reducer) do
    document = reducer.analysis.document

    with {:ok, detail_range} <- Ast.Range.fetch(call, document),
         {:ok, module} <- Analyzer.current_module(reducer.analysis, detail_range.start),
         {:ok, {delegated_module, delegated_name, _delegated_arity}} <-
           fetch_delegated_mfa(node, reducer.analysis, detail_range.start) do
      {delegate_name, args} = Macro.decompose_call(call)
      arity = length(args)
      metadata = %{original_mfa: Subject.mfa(delegated_module, delegated_name, arity)}

      entry =
        Entry.definition(
          document.path,
          Reducer.current_block(reducer),
          Subject.mfa(module, delegate_name, arity),
          {:function, :delegate},
          detail_range,
          Application.get_application(module)
        )

      {:ok, Entry.put_metadata(entry, metadata)}
    else
      _ ->
        :ignored
    end
  end

  def extract(_ast, _reducer) do
    :ignored
  end

  def fetch_delegated_mfa({:defdelegate, _, [call | keywords]}, analysis, position) do
    {_, keyword_args} =
      Macro.prewalk(keywords, [], fn
        {{:__block__, _, [:to]}, {:__aliases__, _, delegated_module}} = ast, acc ->
          {ast, Keyword.put(acc, :to, delegated_module)}

        {{:__block__, _, [:as]}, {:__block__, _, [remote_fun_name]}} = ast, acc ->
          {ast, Keyword.put(acc, :as, remote_fun_name)}

        ast, acc ->
          {ast, acc}
      end)

    with {function_name, args} <- Macro.decompose_call(call),
         {:ok, module} <- Analyzer.expand_alias(keyword_args[:to], analysis, position) do
      function_name = Keyword.get(keyword_args, :as, function_name)
      {:ok, {module, function_name, length(args)}}
    else
      _ ->
        :error
    end
  end

  defp type(:def), do: {:function, :public}
  defp type(:defp), do: {:function, :private}

  defp fun_name_and_arity({:when, _, [{fun_name, _, fun_args} | _]}) do
    # a function with guards
    {fun_name, arity(fun_args)}
  end

  defp fun_name_and_arity({fun_name, _, fun_args}) do
    {fun_name, arity(fun_args)}
  end

  defp arity(nil), do: 0
  defp arity(args) when is_list(args), do: length(args)

  defp block_range(%Analysis{} = analysis, def_ast) do
    case Ast.Range.fetch(def_ast, analysis.document) do
      {:ok, range} -> range
      _ -> nil
    end
  end
end
