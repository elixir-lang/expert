defmodule Engine.CodeIntelligence.References do
  alias Engine.Analyzer
  alias Engine.CodeIntelligence.Entity
  alias Engine.CodeIntelligence.Variable
  alias Engine.Search.Store
  alias Engine.Search.Subject
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Location
  alias Forge.Document.Position
  alias Forge.Search.Indexer.Entry

  require Logger

  def references(%Analysis{} = analysis, %Position{} = position, include_definitions?) do
    with {:ok, resolved, _range} <- Entity.resolve(analysis, position) do
      resolved
      |> maybe_rewrite_resolution(analysis, position)
      |> find_references(analysis, position, include_definitions?)
    end
  end

  defp find_references({:module, module}, _analysis, _position, include_definitions?) do
    subject = Subject.module(module)
    subtype = subtype(include_definitions?)

    query(subject, type: :module, subtype: subtype)
  end

  defp find_references({:struct, struct_module}, _analysis, _position, include_definitions?) do
    subject = Subject.module(struct_module)
    subtype = subtype(include_definitions?)

    query(subject, type: :struct, subtype: subtype)
  end

  defp find_references(
         {:call, module, function_name, _arity},
         _analysis,
         _position,
         include_definitions?
       ) do
    subject = Subject.mfa(module, function_name, "")
    subtype = subtype(include_definitions?)

    case Store.prefix(subject, type: {:function, :_}, subtype: subtype) do
      {:ok, entries} -> Enum.map(entries, &to_location/1)
      _ -> []
    end
  end

  defp find_references(
         {:module_attribute, module, attribute_name},
         _analysis,
         _position,
         include_definitions?
       ) do
    subject = Subject.module_attribute(module, attribute_name)
    subtype = subtype(include_definitions?)

    query(subject, type: :module_attribute, subtype: subtype)
  end

  defp find_references({:variable, var_name}, analysis, position, include_definitions?) do
    analysis
    |> Variable.references(position, var_name, include_definitions?)
    |> Enum.map(&to_location/1)
  end

  defp find_references(resolved, _, _, _include_definitions?) do
    Logger.info("Not attempting to find references for unhandled type: #{inspect(resolved)}")
    :error
  end

  def maybe_rewrite_resolution({:call, Kernel, :defstruct, 1}, analysis, position) do
    case Analyzer.current_module(analysis, position) do
      {:ok, struct_module} -> {:struct, struct_module}
      orig -> orig
    end
  end

  def maybe_rewrite_resolution(resolution, _analysis, _position) do
    resolution
  end

  defp to_location(%Entry{} = entry) do
    uri = Document.Path.ensure_uri(entry.path)
    Location.new(entry.range, uri)
  end

  defp query(subject, opts) do
    case Store.exact(subject, opts) do
      {:ok, entries} -> Enum.map(entries, &to_location/1)
      _ -> []
    end
  end

  defp subtype(true = _include_definitions?), do: :_
  defp subtype(false = _include_definitions?), do: :reference
end
