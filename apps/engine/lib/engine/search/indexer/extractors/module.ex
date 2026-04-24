defmodule Engine.Search.Indexer.Extractors.Module do
  @moduledoc """
  Extracts module references and definitions from AST
  """

  alias Engine.Search.Indexer.Metadata
  alias Engine.Search.Indexer.Source.Reducer
  alias Engine.Search.Subject
  alias Forge.Ast
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Indexer.Source.Block

  require Logger

  @definition_mappings %{
    defmodule: :module,
    defprotocol: {:protocol, :definition}
  }
  @module_definitions Map.keys(@definition_mappings)

  # extract a module definition
  def extract(
        {definition, defmodule_meta,
         [{:__aliases__, module_name_meta, module_name} = module_ast, module_block]} =
          defmodule_ast,
        %Reducer{} = reducer
      )
      when definition in @module_definitions do
    %Block{} = block = Reducer.current_block(reducer)

    with {:ok, aliased_module} <- resolve_alias(reducer, module_name),
         {:ok, detail_range} <- module_range(reducer, module_ast) do
      entry =
        Entry.block_definition(
          reducer.analysis.document.path,
          block,
          Subject.module(aliased_module),
          @definition_mappings[definition],
          block_range(reducer.analysis.document, defmodule_ast),
          detail_range,
          Engine.ApplicationCache.application(aliased_module)
        )

      module_name_meta = Reducer.skip(module_name_meta)

      elem =
        {:defmodule, defmodule_meta,
         [{:__aliases__, module_name_meta, module_name}, module_block]}

      {:ok, entry, elem}
    else
      _ -> :ignored
    end
  end

  # defimpl MyProtocol, for: MyStruct do ...
  def extract(
        {:defimpl, _, [{:__aliases__, _, module_name}, [for_block], _impl_body]} = defimpl_ast,
        %Reducer{} = reducer
      ) do
    %Block{} = block = Reducer.current_block(reducer)

    with {:ok, protocol_module} <- resolve_alias(reducer, module_name),
         {:ok, for_target} <- resolve_for_block(reducer, for_block),
         {:ok, detail_range} <- defimpl_range(reducer, defimpl_ast) do
      implemented_module = Module.concat(protocol_module, for_target)

      implementation_entry =
        Entry.block_definition(
          reducer.analysis.document.path,
          block,
          Subject.module(protocol_module),
          {:protocol, :implementation},
          block_range(reducer.analysis.document, defimpl_ast),
          detail_range,
          Engine.ApplicationCache.application(protocol_module)
        )

      module_entry =
        Entry.copy(implementation_entry,
          subject: Subject.module(implemented_module),
          type: :module
        )

      {:ok, [implementation_entry, module_entry]}
    else
      _ ->
        :ignored
    end
  end

  # This matches an elixir module reference
  def extract({:__aliases__, _metadata, maybe_module} = module_ast, %Reducer{} = reducer)
      when is_list(maybe_module) do
    with {:ok, module} <- module(reducer, maybe_module),
         {:ok, range} <- module_range(reducer, module_ast) do
      %Block{} = current_block = Reducer.current_block(reducer)

      entry =
        Entry.reference(
          reducer.analysis.document.path,
          current_block,
          Subject.module(module),
          :module,
          range,
          Engine.ApplicationCache.application(module)
        )

      {:ok, entry, nil}
    else
      _ -> :ignored
    end
  end

  # This matches __MODULE__ references
  def extract({:__MODULE__, metadata, _} = ast, %Reducer{} = reducer) do
    with {line, _column} <- Metadata.position(metadata),
         pos = Position.new(reducer.analysis.document, line - 1, 1),
         {:ok, current_module} <- Engine.Analyzer.current_module(reducer.analysis, pos),
         {:ok, range} <- module_range(reducer, ast) do
      %Block{} = current_block = Reducer.current_block(reducer)

      entry =
        Entry.reference(
          reducer.analysis.document.path,
          current_block,
          Subject.module(current_module),
          :module,
          range,
          Engine.ApplicationCache.application(current_module)
        )

      {:ok, entry}
    else
      _ -> :ignored
    end
  end

  # This matches an erlang module, which is just an atom
  def extract({:__block__, _metadata, [atom_literal]} = atom_ast, %Reducer{} = reducer)
      when is_atom(atom_literal) do
    with {:ok, module} <- module(reducer, atom_literal),
         {:ok, range} <- module_range(reducer, atom_ast) do
      %Block{} = current_block = Reducer.current_block(reducer)

      entry =
        Entry.reference(
          reducer.analysis.document.path,
          current_block,
          Subject.module(module),
          :module,
          range,
          Engine.ApplicationCache.application(module)
        )

      {:ok, entry}
    else
      _ -> :ignored
    end
  end

  # Function capture with arity: &OtherModule.foo/3
  def extract(
        {:&, _,
         [
           {:/, _,
            [
              {{:., _,
                [{:__aliases__, _start_metadata, maybe_module} = module_ast, _function_name]}, _,
               []},
              _
            ]}
         ]},
        %Reducer{} = reducer
      ) do
    with {:ok, module} <- module(reducer, maybe_module),
         {:ok, range} <- module_range(reducer, module_ast) do
      %Block{} = current_block = Reducer.current_block(reducer)

      entry =
        Entry.reference(
          reducer.analysis.document.path,
          current_block,
          Subject.module(module),
          :module,
          range,
          Engine.ApplicationCache.application(module)
        )

      {:ok, entry}
    else
      _ -> :ignored
    end
  end

  def extract(_, _) do
    :ignored
  end

  defp defimpl_range(%Reducer{} = reducer, {_, protocol_meta, _} = protocol_ast) do
    case {Ast.Range.extract(protocol_ast), Metadata.position(protocol_meta, :do)} do
      {%{start: {start_line, start_column}}, {finish_line, finish_column}} ->
        # add two to include the do
        finish_column = finish_column + 2
        document = reducer.analysis.document

        range =
          Range.new(
            Position.new(document, start_line, start_column),
            Position.new(document, finish_line, finish_column)
          )

        {:ok, range}

      _ ->
        :error
    end
  end

  defp resolve_for_block(
         %Reducer{} = reducer,
         {{:__block__, _, [:for]}, {:__aliases__, _, for_target}}
       ) do
    resolve_alias(reducer, for_target)
  end

  defp resolve_for_block(_, _), do: :error

  defp resolve_alias(%Reducer{} = reducer, unresolved_alias) do
    position = Reducer.position(reducer)

    Engine.Analyzer.expand_alias(unresolved_alias, reducer.analysis, position)
  end

  defp module(%Reducer{} = reducer, maybe_module) when is_list(maybe_module) do
    with true <- Enum.all?(maybe_module, &module_part?/1),
         {:ok, resolved} <- resolve_alias(reducer, maybe_module) do
      {:ok, resolved}
    else
      _ ->
        human_location = Reducer.human_location(reducer)

        Logger.warning(
          "Could not expand module #{inspect(maybe_module)}. Please report this (at #{human_location})"
        )

        :error
    end
  end

  defp module(%Reducer{}, maybe_erlang_module) when is_atom(maybe_erlang_module) do
    if Engine.ApplicationCache.available_module?(maybe_erlang_module) do
      {:ok, maybe_erlang_module}
    else
      :error
    end
  end

  defp module(_, _), do: :error

  @protocol_module_attribute_names [:protocol, :for]

  @starts_with_capital ~r/[A-Z]+/
  defp module_part?(part) when is_atom(part) do
    Regex.match?(@starts_with_capital, Atom.to_string(part))
  end

  defp module_part?({:@, _, [{type, _, _} | _]}) when type in @protocol_module_attribute_names,
    do: true

  defp module_part?({:__MODULE__, _, context}) when is_atom(context), do: true

  defp module_part?(_), do: false

  defp module_range(%Reducer{} = reducer, ast) do
    Ast.Range.fetch(ast, reducer.analysis.document)
  end

  defp block_range(document, ast) do
    case Ast.Range.fetch(ast, document) do
      {:ok, range} -> range
      _ -> nil
    end
  end
end
