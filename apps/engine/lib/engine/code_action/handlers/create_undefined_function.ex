defmodule Engine.CodeAction.Handlers.CreateUndefinedFunction do
  @moduledoc false
  alias Engine.CodeAction
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.CodeAction.Diagnostic
  alias Forge.Document
  alias Forge.Document.Changes
  alias Forge.Document.Edit
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias GenLSP.Enumerations.CodeActionKind

  @behaviour CodeAction.Handler

  @impl CodeAction.Handler
  def actions(%Document{} = doc, %Range{}, diagnostics) do
    Enum.flat_map(diagnostics, fn %Diagnostic{} = diagnostic ->
      with {:ok, function_name, arity} <- extract_function_info(diagnostic),
           {:ok, _doc, %Analysis{valid?: true} = analysis} <-
             Document.Store.fetch(doc.uri, :analysis),
           {:ok, insert_position, indentation} <-
             find_insertion_info(analysis, diagnostic.range.start) do
        build_code_actions(doc, function_name, arity, insert_position, indentation)
      else
        _ ->
          []
      end
    end)
  end

  @impl CodeAction.Handler
  def kinds do
    [CodeActionKind.quick_fix()]
  end

  @impl CodeAction.Handler
  def trigger_kind, do: :all

  defp extract_function_info(%Diagnostic{message: message}) do
    case Regex.run(~r/undefined function (\w+)\/(\d+)/, message) do
      [_, function_name, arity_str] ->
        {:ok, function_name, String.to_integer(arity_str)}

      _ ->
        :error
    end
  end

  defp find_insertion_info(%Analysis{} = analysis, %Position{} = position) do
    range = Range.new(position, position)

    case Analysis.module_scope(analysis, range) do
      %{id: :global} ->
        :error

      %{} = scope ->
        indentation = scope.range.end.character - 1
        insert_info = find_insert_position(analysis, position, scope)
        {:ok, insert_info, indentation}
    end
  end

  defp find_insert_position(%Analysis{} = analysis, %Position{} = position, scope) do
    case find_enclosing_function(analysis, position) do
      {:ok, {name, arity}, enclosing_def} ->
        {:after_function, find_last_clause_end(analysis, {name, arity}, enclosing_def)}

      :error ->
        {:before_module_end, module_end_position(analysis.document, scope)}
    end
  end

  defp find_enclosing_function(%Analysis{} = analysis, %Position{} = position) do
    path = Ast.cursor_path(analysis, position)

    enclosing_def =
      Enum.find(path, fn
        {:def, _, _} -> true
        {:defp, _, _} -> true
        _ -> false
      end)

    case enclosing_def do
      nil ->
        :error

      def_node ->
        case extract_function_signature(def_node) do
          nil -> :error
          {name, arity} -> {:ok, {name, arity}, def_node}
        end
    end
  end

  defp extract_function_signature({def_type, _, [{:when, _, [{name, _, args} | _]} | _]})
       when def_type in [:def, :defp] and is_atom(name),
       do: {name, count_args(args)}

  defp extract_function_signature({def_type, _, [{name, _, args} | _]})
       when def_type in [:def, :defp] and is_atom(name),
       do: {name, count_args(args)}

  defp extract_function_signature(_), do: nil

  defp count_args(nil), do: 0
  defp count_args(args) when is_list(args), do: length(args)

  defp find_last_clause_end(%Analysis{} = analysis, {name, arity}, enclosing_def) do
    all_clauses = find_all_function_clauses(analysis.ast, name, arity)
    last_clause = Enum.max_by(all_clauses, &get_end_line/1, fn -> enclosing_def end)

    %{end: [line: line, column: column]} = Sourceror.get_range(last_clause)
    Position.new(analysis.document, line, column)
  end

  defp get_end_line(node) do
    case Sourceror.get_range(node) do
      %{end: [line: line, column: _]} -> line
      _ -> 0
    end
  end

  defp find_all_function_clauses(ast, name, arity) do
    {_, clauses} =
      Macro.prewalk(ast, [], fn
        {def_type, _, _} = node, acc when def_type in [:def, :defp] ->
          if extract_function_signature(node) == {name, arity} do
            {node, [node | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    clauses
  end

  defp module_end_position(%Document{} = document, scope) do
    end_line = scope.range.end.line
    Position.new(document, end_line, 1)
  end

  defp build_code_actions(doc, function_name, arity, insert_position, indentation) do
    [
      build_code_action(doc, function_name, arity, :def, insert_position, indentation),
      build_code_action(doc, function_name, arity, :defp, insert_position, indentation)
    ]
  end

  defp build_code_action(doc, function_name, arity, visibility, insert_info, indentation) do
    visibility_label = if visibility == :def, do: "public", else: "private"
    title = "Create #{visibility_label} function #{function_name}/#{arity}"

    {position_type, insert_position} = insert_info

    function_text =
      generate_function_text(function_name, arity, visibility, indentation, position_type)

    insert_range = Range.new(insert_position, insert_position)
    edit = Edit.new(function_text, insert_range)
    changes = Changes.new(doc, [edit])

    Forge.CodeAction.new(doc.uri, title, CodeActionKind.quick_fix(), changes)
  end

  defp generate_function_text(name, arity, visibility, indentation, position_type) do
    params = generate_params(arity)
    indent = String.duplicate(" ", indentation)
    body = "#{indent}#{visibility} #{name}#{params} do\n#{indent}end"

    case position_type do
      :after_function -> "\n\n" <> body
      :before_module_end -> "\n" <> body <> "\n"
    end
  end

  defp generate_params(0), do: ""

  defp generate_params(arity) do
    params = for i <- 1..arity, do: "param#{i}"
    "(#{Enum.join(params, ", ")})"
  end
end
