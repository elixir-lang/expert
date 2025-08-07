defmodule Engine.Search.Store.Backends.Ets.Schema do
  @moduledoc """
  A use-able module that allows ETS schemas to be created and migrated.

  This module allows users to define ETS key-based schemas for our search backends. These modules
  are versioned, and are all stored in their own ETS tables. This is so that a single ETS table can
  never have more than one schema.

  Schemas also support migrations. An optional `migrate` function receives old entries and is expected
  transform them into the newer version. The results of this function will be loaded into the schema's
  ETS table. If an empty list is returned, a full reindex will take place.
  """
  defmacro __using__(opts) do
    version = Keyword.fetch!(opts, :version)

    quote do
      @behaviour unquote(__MODULE__)
      @version unquote(version)
      alias Forge.Project
      import unquote(__MODULE__), only: [defkey: 2]

      def version do
        @version
      end

      def index_file_name do
        "source.index.v#{@version}.ets"
      end

      def table_name do
        :"expert_search_v#{@version}"
      end

      def table_options do
        [:named_table, :set]
      end

      def migrate(entries) do
        {:ok, entries}
      end

      defoverridable migrate: 1, index_file_name: 0, table_options: 0
    end
  end

  alias Engine.Search.Store.Backends.Ets.Wal
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  import Wal, only: :macros

  @type write_concurrency_alternative :: boolean() | :auto
  @type table_tweak ::
          :compressed
          | {:write_concurrency, write_concurrency_alternative()}
          | {:read_concurrency, boolean()}
          | {:decentralized_counters, boolean()}

  @type table_option :: :ets.table_type() | table_tweak()

  @type key :: tuple()
  @type row :: {key, tuple()}

  @callback index_file_name() :: String.t()
  @callback table_options() :: [table_option()]
  @callback to_rows(Entry.t()) :: [row()]
  @callback migrate([Entry.t()]) :: {:ok, [row()]} | {:error, term()}

  defmacro defkey(name, fields) do
    query_keys = Enum.map(fields, fn name -> {name, :_} end)
    query_record_name = :"query_#{name}"

    quote location: :keep do
      require Record

      Record.defrecord(unquote(name), unquote(fields))
      Record.defrecord(unquote(query_record_name), unquote(name), unquote(query_keys))
    end
  end

  @spec entries_to_rows(Enumerable.t(Entry.t()), module()) :: [tuple()]
  def entries_to_rows(entries, schema_module) do
    entries
    |> Stream.flat_map(&schema_module.to_rows(&1))
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.update(acc, key, [value], fn old_values -> [value | old_values] end)
    end)
    |> Enum.to_list()
  end

  def load(%Project{} = project, schema_order) do
    ensure_unique_versions(schema_order)

    with {:ok, initial_schema, chain} <- upgrade_chain(project, schema_order),
         {:ok, wal, table_name, entries} <- load_initial_schema(project, initial_schema) do
      handle_upgrade_chain(chain, project, wal, table_name, entries)
    else
      _ ->
        schema_module = List.last(schema_order)
        table_name = schema_module.table_name()
        ensure_schema_table_exists(table_name, schema_module.table_options())

        {:ok, new_wal} = Wal.load(project, schema_module.version(), schema_module.table_name())

        {:ok, new_wal, table_name, :empty}
    end
  end

  defp load_status([]), do: :empty
  defp load_status(_entries), do: :stale

  defp handle_upgrade_chain([_schema_module], _project, wal, table_name, entries) do
    # this case is that there are no migrations to perform
    # we get a single entry, which is the schema module

    {:ok, wal, table_name, load_status(entries)}
  end

  defp handle_upgrade_chain(chain, project, _wal, _table_name, entries) do
    with {:ok, schema_module, entries} <- apply_migrations(project, chain, entries),
         {:ok, new_wal, dest_table_name} <- populate_schema_table(project, schema_module, entries) do
      {:ok, new_wal, dest_table_name, load_status(entries)}
    end
  end

  defp apply_migrations(_project, [initial], entries) do
    {:ok, initial, entries}
  end

  defp apply_migrations(project, chain, entries) do
    Enum.reduce_while(chain, {:ok, nil, entries}, fn
      initial, {:ok, nil, entries} ->
        Wal.destroy(project, initial.version())
        {:cont, {:ok, initial, entries}}

      to, {:ok, _, entries} ->
        case to.migrate(entries) do
          {:ok, new_entries} ->
            Wal.destroy(project, to.version())
            {:cont, {:ok, to, new_entries}}

          error ->
            {:halt, error}
        end
    end)
  end

  defp populate_schema_table(%Project{} = project, schema_module, entries) do
    dest_table_name = schema_module.table_name()
    ensure_schema_table_exists(dest_table_name, schema_module.table_options())

    with {:ok, wal} <- Wal.load(project, schema_module.version(), dest_table_name),
         {:ok, new_wal_state} <- do_populate_schema(wal, dest_table_name, entries),
         {:ok, checkpoint_wal} <- Wal.checkpoint(new_wal_state) do
      {:ok, checkpoint_wal, dest_table_name}
    end
  end

  defp do_populate_schema(%Wal{} = wal, table_name, entries) do
    result =
      with_wal wal do
        :ets.delete_all_objects(table_name)
        :ets.insert(table_name, entries)
      end

    case result do
      {:ok, new_wal_state, _} -> {:ok, new_wal_state}
      error -> error
    end
  end

  defp ensure_schema_table_exists(table_name, table_options) do
    case :ets.whereis(table_name) do
      :undefined -> :ets.new(table_name, table_options)
      _ -> table_name
    end
  end

  defp load_initial_schema(%Project{} = project, schema_module) do
    table_name = schema_module.table_name()
    ensure_schema_table_exists(table_name, schema_module.table_options())

    case Wal.load(project, schema_module.version(), table_name) do
      {:ok, wal} -> {:ok, wal, table_name, :ets.tab2list(table_name)}
      error -> error
    end
  end

  defp upgrade_chain(%Project{} = project, schema_order) do
    {_, initial_schema, schemas} =
      schema_order
      |> Enum.reduce({:not_found, nil, []}, fn
        schema_module, {:not_found, nil, _} ->
          if Wal.exists?(project, schema_module.version()) do
            {:found, schema_module, [schema_module]}
          else
            {:not_found, nil, []}
          end

        schema_module, {:found, initial_schema, chain} ->
          {:found, initial_schema, [schema_module | chain]}
      end)

    case Enum.reverse(schemas) do
      [] ->
        :error

      other ->
        {:ok, initial_schema, other}
    end
  end

  defp ensure_unique_versions(schemas) do
    Enum.reduce(schemas, %{}, fn schema, seen_versions ->
      schema_version = schema.version()

      case seen_versions do
        %{^schema_version => previous_schema} ->
          message =
            "Version Conflict. #{inspect(schema)} had a version that matches #{inspect(previous_schema)}"

          raise ArgumentError.exception(message)

        _ ->
          Map.put(seen_versions, schema_version, schema)
      end
    end)
  end
end
