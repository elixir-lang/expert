defmodule Engine.CodeIntelligence.Docs do
  alias Engine.Modules
  alias Forge.CodeIntelligence.Docs
  alias Forge.CodeIntelligence.Docs.Entry

  @moduledoc """
  Utilities for fetching documentation for a compiled module.
  """

  @doc """
  Fetches known documentation for the given module.

  ## Options

    * `:exclude_hidden` - if `true`, returns `{:error, :hidden}` for
      modules that have been marked as hidden using `@moduledoc false`.
      Defaults to `false`.

  """
  @spec for_module(module(), [opt]) :: {:ok, Docs.t()} | {:error, any()}
        when opt: {:exclude_hidden, boolean()}
  def for_module(module, opts) when is_atom(module) do
    exclude_hidden? = Keyword.get(opts, :exclude_hidden, false)

    with {:ok, beam} <- Modules.ensure_beam(module),
         {:ok, docs} <- parse_docs(module, beam) do
      if docs.doc == :hidden and exclude_hidden? do
        {:error, :hidden}
      else
        {:ok, docs}
      end
    end
  end

  defp parse_docs(module, beam) do
    case Modules.fetch_docs(beam) do
      {:ok, {:docs_v1, _anno, _lang, _format, module_doc, _meta, entries}} ->
        entries_by_kind = Enum.group_by(entries, &doc_kind/1)
        function_entries = Map.get(entries_by_kind, :function, [])
        macro_entries = Map.get(entries_by_kind, :macro, [])
        callback_entries = Map.get(entries_by_kind, :callback, [])
        type_entries = Map.get(entries_by_kind, :type, [])

        spec_defs = beam |> Modules.fetch_specs() |> ok_or([])
        callback_defs = beam |> Modules.fetch_callbacks() |> ok_or([])
        type_defs = beam |> Modules.fetch_types() |> ok_or([])

        result = %Docs{
          module: module,
          doc: Entry.parse_doc(module_doc),
          functions_and_macros:
            parse_entries(module, function_entries ++ macro_entries, spec_defs),
          callbacks: parse_entries(module, callback_entries, callback_defs),
          types: parse_entries(module, type_entries, type_defs)
        }

        {:ok, result}

      _ ->
        {:error, :no_docs}
    end
  end

  defp doc_kind({{kind, _name, _arity}, _anno, _sig, _doc, _meta}) do
    kind
  end

  defp parse_entries(module, raw_entries, defs) do
    defs_by_name_arity =
      Enum.group_by(
        defs,
        fn {name, arity, _formatted, _quoted} -> {name, arity} end,
        fn {_name, _arity, formatted, _quoted} -> formatted end
      )

    raw_entries
    |> Enum.map(fn raw_entry ->
      entry = Entry.from_docs_v1(module, raw_entry)
      defs = Map.get(defs_by_name_arity, {entry.name, entry.arity}, [])
      %Entry{entry | defs: defs}
    end)
    |> Enum.group_by(& &1.name)
  end

  defp ok_or({:ok, value}, _default), do: value
  defp ok_or(_, default), do: default
end
