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
  alias Forge.ProcessCache
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
         [{:__aliases__, module_name_meta, module_name}, module_block]} = defmodule_ast,
        %Reducer{} = reducer
      )
      when definition in @module_definitions do
    %Block{} = block = Reducer.current_block(reducer)

    case resolve_alias(reducer, module_name) do
      {:ok, aliased_module} ->
        module_position = Metadata.position(module_name_meta)
        detail_range = to_range(reducer, module_name, module_position)

        entry =
          Entry.block_definition(
            reducer.analysis.document.path,
            block,
            Subject.module(aliased_module),
            @definition_mappings[definition],
            block_range(reducer.analysis.document, defmodule_ast),
            detail_range,
            Application.get_application(aliased_module)
          )

        module_name_meta = Reducer.skip(module_name_meta)

        elem =
          {:defmodule, defmodule_meta,
           [{:__aliases__, module_name_meta, module_name}, module_block]}

        {:ok, entry, elem}

      _ ->
        :ignored
    end
  end

  # defimpl MyProtocol, for: MyStruct do ...
  def extract(
        {:defimpl, _, [{:__aliases__, _, module_name}, [for_block], _impl_body]} = defimpl_ast,
        %Reducer{} = reducer
      ) do
    %Block{} = block = Reducer.current_block(reducer)

    with {:ok, protocol_module} <- resolve_alias(reducer, module_name),
         {:ok, for_target} <- resolve_for_block(reducer, for_block) do
      detail_range = defimpl_range(reducer, defimpl_ast)
      implemented_module = Module.concat(protocol_module, for_target)

      implementation_entry =
        Entry.block_definition(
          reducer.analysis.document.path,
          block,
          Subject.module(protocol_module),
          {:protocol, :implementation},
          block_range(reducer.analysis.document, defimpl_ast),
          detail_range,
          Application.get_application(protocol_module)
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
  def extract({:__aliases__, metadata, maybe_module}, %Reducer{} = reducer)
      when is_list(maybe_module) do
    case module(reducer, maybe_module) do
      {:ok, module} ->
        start = Metadata.position(metadata)
        range = to_range(reducer, maybe_module, start)
        %Block{} = current_block = Reducer.current_block(reducer)

        entry =
          Entry.reference(
            reducer.analysis.document.path,
            current_block,
            Subject.module(module),
            :module,
            range,
            Application.get_application(module)
          )

        {:ok, entry, nil}

      _ ->
        :ignored
    end
  end

  @module_length String.length("__MODULE__")
  # This matches __MODULE__ references
  def extract({:__MODULE__, metadata, _} = ast, %Reducer{} = reducer) do
    line = Sourceror.get_line(ast)
    pos = Position.new(reducer.analysis.document, line - 1, 1)

    case Engine.Analyzer.current_module(reducer.analysis, pos) do
      {:ok, current_module} ->
        {start_line, start_col} = Metadata.position(metadata)
        start_pos = Position.new(reducer.analysis.document, start_line, start_col)

        end_pos =
          Position.new(
            reducer.analysis.document,
            start_line,
            start_col + @module_length
          )

        range = Range.new(start_pos, end_pos)
        %Block{} = current_block = Reducer.current_block(reducer)

        entry =
          Entry.reference(
            reducer.analysis.document.path,
            current_block,
            Subject.module(current_module),
            :module,
            range,
            Application.get_application(current_module)
          )

        {:ok, entry}

      _ ->
        :ignored
    end
  end

  # This matches an erlang module, which is just an atom
  def extract({:__block__, metadata, [atom_literal]}, %Reducer{} = reducer)
      when is_atom(atom_literal) do
    case module(reducer, atom_literal) do
      {:ok, module} ->
        start = Metadata.position(metadata)
        %Block{} = current_block = Reducer.current_block(reducer)
        range = to_range(reducer, module, start)

        entry =
          Entry.reference(
            reducer.analysis.document.path,
            current_block,
            Subject.module(module),
            :module,
            range,
            Application.get_application(module)
          )

        {:ok, entry}

      :error ->
        :ignored
    end
  end

  # Function capture with arity: &OtherModule.foo/3
  def extract(
        {:&, _,
         [
           {:/, _,
            [
              {{:., _, [{:__aliases__, start_metadata, maybe_module}, _function_name]}, _, []},
              _
            ]}
         ]},
        %Reducer{} = reducer
      ) do
    case module(reducer, maybe_module) do
      {:ok, module} ->
        start = Metadata.position(start_metadata)
        range = to_range(reducer, maybe_module, start)
        %Block{} = current_block = Reducer.current_block(reducer)

        entry =
          Entry.reference(
            reducer.analysis.document.path,
            current_block,
            Subject.module(module),
            :module,
            range,
            Application.get_application(module)
          )

        {:ok, entry}

      _ ->
        :ignored
    end
  end

  def extract(_, _) do
    :ignored
  end

  defp defimpl_range(%Reducer{} = reducer, {_, protocol_meta, _} = protocol_ast) do
    start = Sourceror.get_start_position(protocol_ast)
    {finish_line, finish_column} = Metadata.position(protocol_meta, :do)
    # add two to include the do
    finish_column = finish_column + 2
    document = reducer.analysis.document

    Range.new(
      Position.new(document, start[:line], start[:column]),
      Position.new(document, finish_line, finish_column)
    )
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
    if available_module?(maybe_erlang_module) do
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

  defp available_module?(potential_module) do
    MapSet.member?(all_modules(), potential_module)
  end

  defp all_modules do
    ProcessCache.trans(:all_modules, fn ->
      MapSet.new(:code.all_available(), fn {module_charlist, _, _} ->
        List.to_atom(module_charlist)
      end)
    end)
  end

  # handles @protocol and @for in defimpl blocks
  defp to_range(%Reducer{} = reducer, [{:@, _, [{type, _, _} | _]} = attribute | segments], _)
       when type in @protocol_module_attribute_names do
    range = Sourceror.get_range(attribute)

    document = reducer.analysis.document
    module_length = segments |> Ast.Module.name() |> String.length()
    # add one because we're off by the @ sign
    end_column = range.end[:column] + module_length + 1

    Range.new(
      Position.new(document, range.start[:line], range.start[:column]),
      Position.new(document, range.end[:line], end_column)
    )
  end

  defp to_range(%Reducer{} = reducer, module_name, {line, column}) do
    document = reducer.analysis.document

    module_length =
      module_name
      |> Ast.Module.name()
      |> String.length()

    Range.new(
      Position.new(document, line, column),
      Position.new(document, line, column + module_length)
    )
  end

  defp block_range(document, ast) do
    case Ast.Range.fetch(ast, document) do
      {:ok, range} -> range
      _ -> nil
    end
  end
end
