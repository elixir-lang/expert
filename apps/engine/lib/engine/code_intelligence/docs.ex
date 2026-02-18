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
            parse_entries(module, function_entries ++ macro_entries, spec_defs,
              include_not_documented?: true
            ),
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

  defp parse_entries(module, raw_entries, defs, opts \\ []) do
    defs_by_name_arity =
      Enum.group_by(
        defs,
        fn {name, arity, _formatted, _quoted} -> {name, arity} end,
        fn {_name, _arity, formatted, _quoted} -> formatted end
      )

    docs_entries =
      for raw_entry <- raw_entries do
        entry = Entry.from_docs_v1(module, raw_entry)
        entry_defs = Map.get(defs_by_name_arity, {entry.name, entry.arity}, [])
        %Entry{entry | defs: entry_defs}
      end

    not_documented_entries =
      if Keyword.get(opts, :include_not_documented?, false) do
        docs_names = MapSet.new(docs_entries, & &1.name)
        docs_name_arities = MapSet.new(docs_entries, &{&1.name, &1.arity})

        for {name, arity, formatted, _quoted} <- defs,
            not MapSet.member?(docs_name_arities, {name, arity}),
            not MapSet.member?(docs_names, name) do
          %Entry{
            module: module,
            kind: :function,
            name: name,
            arity: arity,
            signature: [generate_signature(name, arity)],
            doc: :none,
            defs: [formatted]
          }
        end
      else
        []
      end

    Enum.group_by(docs_entries ++ not_documented_entries, & &1.name)
  end

  defp generate_signature(name, arity) do
    args = for i <- 1..arity, do: "arg#{i}"
    "#{name}(#{Enum.join(args, ", ")})"
  end

  defp ok_or({:ok, value}, _default), do: value
  defp ok_or(_, default), do: default
end
