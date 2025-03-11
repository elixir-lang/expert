defmodule Lexical.RemoteControl.CodeAction.Handlers.ReplaceRemoteFunction do
  alias Lexical.Ast
  alias Lexical.Document
  alias Lexical.Document.Changes
  alias Lexical.Document.Edit
  alias Lexical.Document.Range
  alias Lexical.RemoteControl
  alias Lexical.RemoteControl.CodeAction
  alias Lexical.RemoteControl.CodeAction.Diagnostic
  alias Lexical.RemoteControl.Modules
  alias Sourceror.Zipper

  @behaviour CodeAction.Handler

  @impl CodeAction.Handler
  def actions(%Document{} = doc, %Range{}, diagnostics) do
    Enum.flat_map(diagnostics, fn %Diagnostic{} = diagnostic ->
      with {:ok, module, function, arity, line_number} <- extract_function_and_line(diagnostic),
           {:ok, suggestions} <- prepare_suggestions(module, function, arity) do
        to_code_actions(doc, line_number, module, function, suggestions)
      else
        _ -> []
      end
    end)
  end

  @impl CodeAction.Handler
  def kinds, do: [:quick_fix]

  @impl CodeAction.Handler
  def trigger_kind, do: :all

  @spec to_code_actions(Document.t(), non_neg_integer(), module(), String.t(), [atom()]) ::
          [CodeAction.t()]
  defp to_code_actions(%Document{} = doc, line_number, module, function, suggestions) do
    suggestions
    |> Enum.reduce([], fn suggestion, acc ->
      case apply_transform(doc, line_number, module, function, suggestion) do
        {:ok, edits} ->
          changes = Changes.new(doc, edits)
          code_action = CodeAction.new(doc.uri, "Rename to #{suggestion}", :quick_fix, changes)

          [code_action | acc]

        :error ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  @spec apply_transform(Document.t(), non_neg_integer(), module(), String.t(), atom()) ::
          {:ok, [Edit.t()]} | :error
  defp apply_transform(%Document{} = doc, line_number, module, function, suggestion) do
    {:ok, doc, analysis} = Document.Store.fetch(doc.uri, :analysis)
    function_atom = String.to_atom(function)
    position = Document.Position.new(doc, line_number, 0)

    doc
    |> Ast.traverse_line(line_number, [], fn
      %Zipper{node: {{:., _, [{:__aliases__, _, module_alias}, ^function_atom]}, _, _}} = zipper,
      patches ->
        case RemoteControl.Analyzer.expand_alias(module_alias, analysis, position) do
          {:ok, ^module} ->
            patch = Sourceror.Patch.rename_call(zipper.node, suggestion)
            {zipper, [patch | patches]}

          _ ->
            {zipper, patches}
        end

      %Zipper{node: {{:., _, [{:__block__, _, [^module]}, ^function_atom]}, _, _}} = zipper,
      patches ->
        # this is an erlang call :ets.insert(...)
        patch = Sourceror.Patch.rename_call(zipper.node, suggestion)

        {zipper, [patch | patches]}

      zipper, patches ->
        {zipper, patches}
    end)
    |> case do
      {:ok, _zipper, patches} ->
        Ast.patches_to_edits(doc, patches)

      _ ->
        :error
    end
  end

  defp extract_function_and_line(%Diagnostic{} = diagnostic) do
    with {:ok, module, function, arity} <- extract_function(diagnostic.message) do
      {:ok, module, function, arity, diagnostic.range.start.line}
    end
  end

  @function_re ~r/(warning: |function )?([^\/]+)\/(.*) is undefined or private. Did you mean:.*/
  defp extract_function(message) do
    result =
      with [[_, _, module_and_function, arity]] <- Regex.scan(@function_re, message),
           {:ok, module, function_name} <- separate_module_from_function(module_and_function) do
        {:ok, module, function_name, String.to_integer(arity)}
      end

    result
  end

  defp separate_module_from_function(module_and_function) do
    module_and_function
    |> String.split(".")
    |> List.pop_at(-1)
    |> case do
      {function_name, [_ | _] = module_alias} ->
        {:ok, alias_to_module(module_alias), function_name}

      _ ->
        :error
    end
  end

  defp alias_to_module([":" <> erlang_alias]) do
    String.to_atom(erlang_alias)
  end

  defp alias_to_module(module_alias) do
    Module.concat(module_alias)
  end

  @function_threshold 0.77
  @max_suggestions 5
  defp prepare_suggestions(module, function, arity) do
    with {:ok, module_functions} <- Modules.fetch_functions(module) do
      suggestions =
        for {module_function, ^arity} <- module_functions,
            distance = module_function |> Atom.to_string() |> String.jaro_distance(function),
            distance >= @function_threshold do
          {distance, module_function}
        end
        |> Enum.sort(:desc)
        |> Enum.take(@max_suggestions)
        |> Enum.map(fn {_distance, module_function} -> module_function end)

      {:ok, suggestions}
    end
  end
end
