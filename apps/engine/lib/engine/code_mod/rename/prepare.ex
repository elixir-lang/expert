defmodule Engine.CodeMod.Rename.Prepare do
  @moduledoc """
  Handles the preparation phase of rename operations.

  The preparation phase determines:
  - Whether the entity at the cursor can be renamed
  - What the current name is
  - What range should be replaced
  """
  alias Engine.CodeIntelligence.Entity
  alias Engine.CodeMod.Rename
  alias Forge.Ast.Analysis
  alias Forge.Document.Position
  alias Forge.Document.Range

  require Logger

  @renaming_modules [Rename.Function]

  @spec prepare(Analysis.t(), Position.t()) ::
          {:ok, String.t(), Range.t()} | {:ok, nil} | {:error, term()}
  def prepare(%Analysis{} = analysis, %Position{} = position) do
    case resolve(analysis, position) do
      {:ok, {:function, {_module, fun_name, _arity}}, range} ->
        name = Atom.to_string(fun_name)
        {:ok, name, narrow_to_name(range, name)}

      {:error, {:unsupported_location, _}} ->
        {:ok, nil}

      {:error, {:unsupported_entity, _entity_type}} ->
        {:ok, nil}

      {:error, error} ->
        {:error, error}
    end
  end

  # For qualified calls like `Foo.Bar.call`, `Entity.resolve` returns a range
  # covering the whole dotted expression. The actual rename only touches the
  # function name token, so narrow the range to the trailing `name` so that the
  # editor highlights and replaces only that portion.
  defp narrow_to_name(%Range{end: end_pos} = range, name) do
    new_start = %{end_pos | character: end_pos.character - String.length(name)}
    %{range | start: new_start}
  end

  @spec resolve(Analysis.t(), Position.t()) ::
          {:ok, {atom(), atom()}, Range.t()} | {:error, tuple() | atom()}
  def resolve(%Analysis{} = analysis, %Position{} = position) do
    prepare_result =
      Enum.find_value(@renaming_modules, fn module ->
        if module.recognizes?(analysis, position) do
          module.prepare(analysis, position)
        end
      end)

    prepare_result || handle_unsupported_entity(analysis, position)
  end

  defp handle_unsupported_entity(analysis, position) do
    with {:ok, other, _range} <- Entity.resolve(analysis, position) do
      Logger.info("Unsupported entity for renaming: #{inspect(other)}")
      {:error, {:unsupported_entity, elem(other, 0)}}
    end
  end
end
