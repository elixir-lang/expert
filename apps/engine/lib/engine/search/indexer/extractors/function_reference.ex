defmodule Engine.Search.Indexer.Extractors.FunctionReference do
  alias Engine.Search.Indexer.Extractors.FunctionDefinition
  alias Engine.Search.Indexer.Metadata
  alias Engine.Search.Indexer.Source.Reducer
  alias Engine.Search.Subject
  alias Forge.Ast
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry

  require Logger

  @excluded_functions_key {__MODULE__, :excluded_functions}
  # Dynamic calls using apply apply(Module, :function, [1, 2])
  def extract(
        {:apply, apply_meta,
         [
           {:__aliases__, _, module},
           {:__block__, _, [function_name]},
           {:__block__, _,
            [
              arg_list
            ]}
         ]},
        %Reducer{} = reducer
      )
      when is_list(arg_list) and is_atom(function_name) do
    entry = entry(reducer, apply_meta, apply_meta, module, function_name, arg_list)
    {:ok, entry, nil}
  end

  # Dynamic call via Kernel.apply Kernel.apply(Module, :function, [1, 2])
  def extract(
        {{:., _, [{:__aliases__, start_metadata, [:Kernel]}, :apply]}, apply_meta,
         [
           {:__aliases__, _, module},
           {:__block__, _, [function_name]},
           {:__block__, _, [arg_list]}
         ]},
        %Reducer{} = reducer
      )
      when is_list(arg_list) and is_atom(function_name) do
    entry = entry(reducer, start_metadata, apply_meta, module, function_name, arg_list)
    {:ok, entry, nil}
  end

  # remote function OtherModule.foo(:arg), OtherModule.foo() or OtherModule.foo
  def extract(
        {{:., _, [{:__aliases__, start_metadata, module}, fn_name]}, end_metadata, args},
        %Reducer{} = reducer
      )
      when is_atom(fn_name) do
    entry = entry(reducer, start_metadata, end_metadata, module, fn_name, args)

    {:ok, entry}
  end

  # local function capture &downcase/1
  def extract(
        {:/, _, [{fn_name, end_metadata, nil}, {:__block__, arity_meta, [arity]}]},
        %Reducer{} = reducer
      ) do
    position = Reducer.position(reducer)

    {module, _, _} =
      Engine.Analyzer.resolve_local_call(reducer.analysis, position, fn_name, arity)

    entry = entry(reducer, end_metadata, arity_meta, module, fn_name, arity)
    {:ok, entry, nil}
  end

  # Function capture with arity: &OtherModule.foo/3
  def extract(
        {:&, _,
         [
           {:/, _,
            [
              {{:., _, [{:__aliases__, start_metadata, module}, function_name]}, _, []},
              {:__block__, end_metadata, [arity]}
            ]}
         ]},
        %Reducer{} = reducer
      ) do
    entry = entry(reducer, start_metadata, end_metadata, module, function_name, arity)

    # we return nil here to stop analysis from progressing down the syntax tree,
    # because if it did, the function head that deals with normal calls will pick
    # up the rest of the call and return a reference to MyModule.function/0, which
    # is incorrect
    {:ok, entry, nil}
  end

  def extract({:|>, pipe_meta, [pipe_start, {fn_name, meta, args}]}, %Reducer{}) do
    # we're in a pipeline. Skip this node by returning nil, but add a marker to the metadata
    # that will be picked up by call_arity.
    updated_meta = Keyword.put(meta, :pipeline?, true)
    new_pipe = {:|>, pipe_meta, [pipe_start, {fn_name, updated_meta, args}]}

    {:ok, nil, new_pipe}
  end

  def extract({:defdelegate, _, _} = ast, %Reducer{} = reducer) do
    analysis = reducer.analysis
    position = Reducer.position(reducer)

    case FunctionDefinition.fetch_delegated_mfa(ast, analysis, position) do
      {:ok, {module, function_name, arity}} ->
        entry =
          Entry.reference(
            analysis.document.path,
            Reducer.current_block(reducer),
            Forge.Formats.mfa(module, function_name, arity),
            {:function, :usage},
            Ast.Range.get(ast, analysis.document),
            Application.get_application(module)
          )

        {:ok, entry, []}

      _ ->
        :ignored
    end
  end

  # local function call foo() foo(arg)
  def extract({fn_name, meta, args}, %Reducer{} = reducer)
      when is_atom(fn_name) and is_list(args) do
    if fn_name in excluded_functions() do
      :ignored
    else
      arity = call_arity(args, meta)
      position = Reducer.position(reducer)

      {module, _, _} =
        Engine.Analyzer.resolve_local_call(reducer.analysis, position, fn_name, arity)

      entry = entry(reducer, meta, meta, [module], fn_name, args)

      {:ok, entry}
    end
  end

  def extract(_ast, _reducer) do
    :ignored
  end

  defp entry(
         %Reducer{} = reducer,
         start_metadata,
         end_metadata,
         module,
         function_name,
         args_arity
       ) do
    arity = call_arity(args_arity, end_metadata)
    block = Reducer.current_block(reducer)

    range =
      get_reference_range(reducer.analysis.document, start_metadata, end_metadata, function_name)

    case Engine.Analyzer.expand_alias(module, reducer.analysis, range.start) do
      {:ok, module} ->
        mfa = Subject.mfa(module, function_name, arity)

        Entry.reference(
          reducer.analysis.document.path,
          block,
          mfa,
          {:function, :usage},
          range,
          Application.get_application(module)
        )

      _ ->
        human_location = Reducer.human_location(reducer)

        Logger.warning(
          "Could not expand #{inspect(module)} into an alias. Please report this. (at #{human_location})"
        )

        nil
    end
  end

  defp get_reference_range(document, start_metadata, end_metadata, function_name) do
    {start_line, start_column} = start_position(start_metadata)
    start_position = Position.new(document, start_line, start_column)
    has_parens? = not Keyword.get(end_metadata, :no_parens, false)

    {end_line, end_column} =
      case Metadata.position(end_metadata, :closing) do
        {line, column} ->
          if has_parens? do
            {line, column + 1}
          else
            {line, column}
          end

        nil ->
          {line, column} = Metadata.position(end_metadata)

          if has_parens? do
            {line, column + 1}
          else
            name_length = function_name |> Atom.to_string() |> String.length()
            # without parens, the metadata points to the beginning of the call, so
            # we need to add the length of the function name to be sure we have it
            # all
            {line, column + name_length}
          end
      end

    end_position = Position.new(document, end_line, end_column)
    Range.new(start_position, end_position)
  end

  defp start_position(metadata) do
    Metadata.position(metadata)
  end

  defp call_arity(args, metadata) when is_list(args) do
    length(args) + pipeline_arity(metadata)
  end

  defp call_arity(arity, metadata) when is_integer(arity) do
    arity + pipeline_arity(metadata)
  end

  defp call_arity(_, metadata), do: pipeline_arity(metadata)

  defp pipeline_arity(metadata) do
    if Keyword.get(metadata, :pipeline?, false) do
      1
    else
      0
    end
  end

  defp excluded_functions do
    case :persistent_term.get(@excluded_functions_key, :not_found) do
      :not_found ->
        excluded_functions = build_excluded_functions()
        :persistent_term.put(@excluded_functions_key, excluded_functions)
        excluded_functions

      excluded_functions ->
        excluded_functions
    end
  end

  defp build_excluded_functions do
    excluded_kernel_macros =
      for {macro_name, _arity} <- Kernel.__info__(:macros),
          string_name = Atom.to_string(macro_name),
          String.starts_with?(string_name, "def") do
        macro_name
      end

    # syntax specific functions to exclude from our matches
    excluded_operators =
      ~w[<- -> && ** ++ -- .. "..//" ! <> =~ @ |> | || * + - / != !== < <= == === > >=]a

    excluded_keywords = ~w[and if import in not or raise require try use]a

    excluded_special_forms =
      :macros
      |> Kernel.SpecialForms.__info__()
      |> Keyword.keys()

    excluded_kernel_macros
    |> Enum.concat(excluded_operators)
    |> Enum.concat(excluded_special_forms)
    |> Enum.concat(excluded_keywords)
  end
end
