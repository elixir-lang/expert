defmodule Expert.Search.Store.Backends.Sqlite do
  @behaviour Expert.Search.Store.Backend

  use GenServer

  alias Expert.EngineApi
  alias Expert.Search.Store.Backend
  alias Exqlite.Sqlite3
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  require Entry

  @schema_version 1
  @database_file "source.index.sqlite3"
  @busy_timeout_ms Application.compile_env(:expert, :search_store_sqlite_busy_timeout_ms, 5_000)

  defmodule State do
    defstruct [:conn, :database_path, :project, :runtime_versions]
  end

  @impl Backend
  def new(%Project{} = project) do
    case Process.whereis(name(project)) do
      nil -> {:error, :not_started}
      pid -> {:ok, pid}
    end
  end

  @impl Backend
  def prepare(pid), do: GenServer.call(pid, :prepare, :infinity)

  @impl Backend
  def sync(%Project{} = project), do: GenServer.call(name(project), :sync, :infinity)

  @impl Backend
  def insert(%Project{} = project, entries) do
    GenServer.call(name(project), {:insert, entries}, :infinity)
  end

  @impl Backend
  def drop(%Project{} = project), do: GenServer.call(name(project), :drop, :infinity)

  @impl Backend
  def destroy(%Project{} = project) do
    if pid = Process.whereis(name(project)) do
      GenServer.call(pid, :destroy, :infinity)
    else
      :ok
    end
  end

  def destroy_all(%Project{} = project), do: project |> root_path() |> File.rm_rf!()

  @impl Backend
  def reduce(%Project{} = project, acc, reducer_fun) do
    GenServer.call(name(project), {:reduce, acc, reducer_fun}, :infinity)
  end

  @impl Backend
  def replace_all(%Project{} = project, entries) do
    GenServer.call(name(project), {:replace_all, entries}, :infinity)
  end

  @impl Backend
  def apply_index_update(%Project{} = project, updated_entries, paths_to_clear) do
    GenServer.call(
      name(project),
      {:apply_index_update, updated_entries, paths_to_clear},
      :infinity
    )
  end

  def apply_index_update(pid_or_name, updated_entries, paths_to_clear) do
    GenServer.call(
      pid_or_name,
      {:apply_index_update, updated_entries, paths_to_clear},
      :infinity
    )
  end

  @impl Backend
  def delete_by_path(%Project{} = project, path) do
    GenServer.call(name(project), {:delete_by_path, path}, :infinity)
  end

  @impl Backend
  def find_by_subject(%Project{} = project, subject, type, subtype) do
    GenServer.call(name(project), {:find_by_subject, subject, type, subtype}, :infinity)
  end

  @impl Backend
  def find_by_prefix(%Project{} = project, prefix, type, subtype) do
    GenServer.call(name(project), {:find_by_prefix, prefix, type, subtype}, :infinity)
  end

  @impl Backend
  def find_by_ids(%Project{} = project, ids, type, subtype) do
    GenServer.call(name(project), {:find_by_ids, ids, type, subtype}, :infinity)
  end

  @impl Backend
  def structure_for_path(%Project{} = project, path) do
    GenServer.call(name(project), {:structure_for_path, path}, :infinity)
  end

  @impl Backend
  def siblings(%Project{} = project, %Entry{} = entry) do
    GenServer.call(name(project), {:siblings, entry}, :infinity)
  end

  @impl Backend
  def parent(%Project{} = project, %Entry{} = entry) do
    GenServer.call(name(project), {:parent, entry}, :infinity)
  end

  def start_link(%Project{} = project), do: start_link(project, [])

  def start_link(%Project{} = project, opts) when is_list(opts) do
    gen_server_opts =
      case Keyword.get(opts, :name, name(project)) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, [project, opts], gen_server_opts)
  end

  def child_spec(%Project{} = project) do
    %{id: {__MODULE__, Project.unique_name(project)}, start: {__MODULE__, :start_link, [project]}}
  end

  def child_spec([%Project{} = project | opts]) when is_list(opts) do
    %{
      id: {__MODULE__, Project.unique_name(project)},
      start: {__MODULE__, :start_link, [project, opts]}
    }
  end

  def name(%Project{} = project), do: :"#{Project.unique_name(project)}::search_sqlite_backend"

  def database_path(%Project{} = project, runtime_versions) do
    project
    |> root_path(runtime_versions)
    |> Path.join(@database_file)
  end

  if Mix.env() == :test do
    def root_path(%Project{} = project) do
      Project.workspace_path(project, ["indexes", "sqlite", to_string(Project.entropy(project))])
    end
  else
    def root_path(%Project{} = project),
      do: Project.workspace_path(project, ["indexes", "sqlite"])
  end

  def root_path(%Project{} = project, runtime_versions) do
    Path.join([root_path(project), runtime_versions.erlang, runtime_versions.elixir])
  end

  @impl GenServer
  def init([%Project{} = project, opts]) do
    Process.flag(:fullsweep_after, 5)

    runtime_versions = runtime_versions(project, opts)
    database_path = database_path(project, runtime_versions)

    {:ok,
     %State{
       database_path: database_path,
       project: project,
       runtime_versions: runtime_versions
     }}
  end

  @impl GenServer
  def handle_call(:prepare, _from, %State{} = state) do
    {reply, new_state} = prepare_database(state)
    {:reply, reply, new_state}
  end

  def handle_call(:sync, _from, %State{} = state) do
    {:reply, sync_database(state), state}
  end

  def handle_call(:drop, _from, %State{} = state), do: reply(do_drop(state), state)

  def handle_call({:insert, entries}, _from, %State{} = state),
    do: reply(do_insert(state, entries), state)

  def handle_call({:reduce, acc, reducer_fun}, _from, %State{} = state),
    do: reply(do_reduce(state, acc, reducer_fun), state)

  def handle_call({:replace_all, entries}, _from, %State{} = state),
    do: reply(do_replace_all(state, entries), state)

  def handle_call(
        {:apply_index_update, updated_entries, paths_to_clear},
        _from,
        %State{} = state
      ) do
    reply(do_apply_index_update(state, updated_entries, paths_to_clear), state)
  end

  def handle_call({:delete_by_path, path}, _from, %State{} = state),
    do: reply(do_delete_by_path(state, path), state)

  def handle_call({:find_by_subject, subject, type, subtype}, _from, %State{} = state),
    do: reply(do_find_by_subject(state, subject, type, subtype), state)

  def handle_call({:find_by_prefix, prefix, type, subtype}, _from, %State{} = state),
    do: reply(do_find_by_prefix(state, prefix, type, subtype), state)

  def handle_call({:find_by_ids, ids, type, subtype}, _from, %State{} = state),
    do: reply(do_find_by_ids(state, ids, type, subtype), state)

  def handle_call({:structure_for_path, path}, _from, %State{} = state),
    do: reply(do_structure_for_path(state, path), state)

  def handle_call({:siblings, entry}, _from, %State{} = state),
    do: reply(do_siblings(state, entry), state)

  def handle_call({:parent, entry}, _from, %State{} = state),
    do: reply(do_parent(state, entry), state)

  def handle_call(:destroy, _from, %State{} = state) do
    case reset_database_schema(state) do
      {:ok, _status} -> reply(:ok, state)
      {:error, _} = error -> reply(error, state)
    end
  end

  @impl GenServer
  def terminate(_reason, %State{} = state) do
    close_database(state)
    state
  end

  def do_drop(%State{}), do: :ok

  def do_insert(%State{} = state, entries) when is_list(entries) do
    transaction(state, fn ->
      insert_entries(state, entries)
    end)
  end

  def do_reduce(%State{} = state, acc, reducer_fun) do
    case query(state, "SELECT entry FROM entries ORDER BY id") do
      {:ok, rows} ->
        Enum.reduce(rows, acc, fn [entry_blob], acc ->
          reducer_fun.(decode_term(entry_blob), acc)
        end)

      {:error, _} = error ->
        error
    end
  end

  def do_replace_all(%State{} = state, entries) when is_list(entries) do
    transaction(state, fn ->
      with :ok <- exec(state, "DELETE FROM entries"),
           :ok <- exec(state, "DELETE FROM structures") do
        insert_entries(state, entries)
      end
    end)
  end

  def do_apply_index_update(%State{} = state, updated_entries, paths_to_clear)
      when is_list(updated_entries) and is_list(paths_to_clear) do
    paths = affected_paths(updated_entries, paths_to_clear)

    if paths == [] do
      {:ok, []}
    else
      commit_index_update(state, updated_entries, paths)
    end
  end

  defp commit_index_update(%State{} = state, updated_entries, paths) do
    transaction(state, fn ->
      with {:ok, deleted_ids} <- delete_entries_for_paths(state, paths),
           :ok <- delete_structures_for_paths(state, paths),
           :ok <- insert_entries(state, updated_entries) do
        {:ok, deleted_ids}
      end
    end)
  end

  def do_delete_by_path(%State{} = state, path) do
    transaction(state, fn ->
      with {:ok, ids_to_delete} <- delete_entries_for_paths(state, [path]),
           :ok <- delete_structures_for_paths(state, [path]) do
        {:ok, ids_to_delete}
      end
    end)
  end

  def do_find_by_subject(%State{} = state, subject, type, subtype) do
    {clauses, args} = subject_constraint(subject)
    {where, args} = constraints(clauses, args, type, subtype)

    state
    |> query_entries(where_clause(where), args)
    |> entries_result()
  end

  def do_find_by_prefix(%State{} = state, prefix, type, subtype) do
    {clauses, args} = prefix_constraint(prefix)
    {where, args} = constraints(clauses, args, type, subtype)

    state
    |> query_entries(where_clause(where), args)
    |> entries_result()
  end

  def do_find_by_ids(%State{} = state, ids, type, subtype) when is_list(ids) do
    case ids do
      [] ->
        []

      [_ | _] ->
        {where, args} = constraints(["id IN (#{placeholders(ids)})"], ids, type, subtype)

        with {:ok, rows} <-
               query(state, "SELECT id, entry FROM entries #{where_clause(where)}", args) do
          entries_by_id =
            Enum.group_by(
              rows,
              fn [id, _entry_blob] -> id end,
              fn [_id, entry_blob] -> decode_term(entry_blob) end
            )

          Enum.flat_map(ids, fn id -> Map.get(entries_by_id, id, []) end)
        end
    end
  end

  def do_structure_for_path(%State{} = state, path) do
    case query(state, "SELECT structure FROM structures WHERE path = ? LIMIT 1", [path]) do
      {:ok, [[structure_blob]]} -> {:ok, decode_term(structure_blob)}
      {:ok, []} -> :error
      {:error, _} = error -> error
    end
  end

  def do_siblings(%State{} = state, %Entry{} = entry) do
    case query(
           state,
           "SELECT entry FROM entries WHERE block_id = ? AND path = ? ORDER BY id",
           [block_id_key(entry.block_id), entry.path]
         ) do
      {:ok, rows} ->
        rows
        |> Enum.map(fn [entry_blob] -> decode_term(entry_blob) end)
        |> Enum.filter(&same_block_type?(entry, &1))
        |> Enum.uniq()
        |> then(&{:ok, &1})

      {:error, _} = error ->
        error
    end
  end

  def do_parent(%State{} = state, %Entry{} = entry) do
    with {:ok, structure} <- do_structure_for_path(state, entry.path),
         {:ok, child_path} <- child_path(structure, entry.block_id) do
      child_path = if Entry.is_block(entry), do: tl(child_path), else: child_path
      find_first_by_block_id(state, child_path)
    end
  end

  def do_parent(%State{}, :root), do: :error

  def do_destroy(%State{} = state) do
    with :ok <- close_database(state) do
      remove_database_root(state)
    end
  end

  defp reply(result, %State{} = state), do: {:reply, result, state}

  defp prepare_database(%State{} = state) do
    if state.conn do
      prepare_open_database(state)
    else
      open_database(state)
    end
  end

  defp open_database(%State{} = state) do
    with :ok <- ensure_database_directory(state),
         {:ok, conn} <- Exqlite.Basic.open(state.database_path) do
      state = %State{state | conn: conn}
      prepare_open_database(state)
    else
      {:error, _} = error ->
        {error, state}
    end
  end

  defp prepare_open_database(%State{} = state) do
    case initialize_schema(state) do
      {:ok, status} ->
        {{:ok, status}, state}

      {:error, reason} = error ->
        if recoverable_database_error?(reason) do
          reset_database_file(state)
        else
          {error, state}
        end
    end
  end

  defp initialize_schema(%State{} = state) do
    with :ok <- configure_database(state),
         :ok <- create_schema_table(state),
         {:ok, current_version} <- current_schema_version(state) do
      load_or_reset_schema(state, current_version)
    end
  end

  defp configure_database(%State{} = state) do
    with :ok <- exec(state, "PRAGMA busy_timeout = #{@busy_timeout_ms}"),
         :ok <- exec(state, "PRAGMA synchronous = NORMAL") do
      exec(state, "PRAGMA case_sensitive_like = ON")
    end
  end

  defp load_or_reset_schema(%State{} = state, @schema_version), do: load_status(state)
  defp load_or_reset_schema(%State{} = state, nil), do: reset_schema(state)
  defp load_or_reset_schema(%State{} = state, _version), do: reset_database_schema(state)

  defp create_schema_table(%State{} = state) do
    exec(state, """
    CREATE TABLE IF NOT EXISTS schema (
      id INTEGER PRIMARY KEY,
      version INTEGER NOT NULL,
      inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
    """)
  end

  defp current_schema_version(%State{} = state) do
    case query(state, "SELECT MAX(version) FROM schema") do
      {:ok, [[version]]} -> {:ok, version}
      {:ok, []} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  defp reset_schema(%State{} = state) do
    with :ok <- exec(state, "DROP TABLE IF EXISTS entries"),
         :ok <- exec(state, "DROP TABLE IF EXISTS structures"),
         :ok <- create_entries_table(state),
         :ok <- create_structures_table(state),
         :ok <- create_indexes(state),
         :ok <- exec(state, "INSERT INTO schema (version) VALUES (?)", [@schema_version]) do
      {:ok, :empty}
    end
  end

  defp reset_database_schema(%State{} = state) do
    with :ok <- exec(state, "DROP TABLE IF EXISTS schema"),
         :ok <- exec(state, "DROP TABLE IF EXISTS entries"),
         :ok <- exec(state, "DROP TABLE IF EXISTS structures"),
         :ok <- create_schema_table(state) do
      reset_schema(state)
    end
  end

  defp load_status(%State{} = state) do
    with :ok <- create_entries_table(state),
         :ok <- create_structures_table(state),
         :ok <- create_indexes(state),
         {:ok, [[count]]} <- query(state, "SELECT COUNT(*) FROM entries") do
      if count == 0, do: {:ok, :empty}, else: {:ok, :stale}
    end
  end

  defp create_entries_table(%State{} = state) do
    exec(state, """
    CREATE TABLE IF NOT EXISTS entries (
      id INTEGER,
      path TEXT NOT NULL,
      subject TEXT NOT NULL,
      type BLOB NOT NULL,
      subtype TEXT NOT NULL,
      block_id INTEGER NOT NULL,
      entry BLOB NOT NULL
    )
    """)
  end

  defp create_structures_table(%State{} = state) do
    exec(state, """
    CREATE TABLE IF NOT EXISTS structures (
      path TEXT PRIMARY KEY,
      structure BLOB NOT NULL
    )
    """)
  end

  defp create_indexes(%State{} = state) do
    with :ok <-
           exec(
             state,
             "CREATE INDEX IF NOT EXISTS entries_subject_idx ON entries (subject, type, subtype)"
           ),
         :ok <- exec(state, "CREATE INDEX IF NOT EXISTS entries_path_idx ON entries (path)"),
         :ok <-
           exec(state, "CREATE INDEX IF NOT EXISTS entries_block_idx ON entries (block_id, path)") do
      exec(state, "CREATE INDEX IF NOT EXISTS entries_id_idx ON entries (id, type, subtype)")
    end
  end

  defp insert_entries(%State{} = state, entries) do
    with_prepared_statements(
      state,
      [
        """
        INSERT INTO entries (id, path, subject, type, subtype, block_id, entry)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        "INSERT OR REPLACE INTO structures (path, structure) VALUES (?, ?)"
      ],
      fn [entry_statement, structure_statement] ->
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          case insert_entry(state, entry_statement, structure_statement, entry) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)
      end
    )
  end

  defp insert_entry(%State{} = state, _entry_statement, structure_statement, %Entry{} = entry)
       when Entry.is_structure(entry) do
    exec_statement(state, structure_statement, [entry.path, blob(entry.subject)])
  end

  defp insert_entry(%State{} = state, entry_statement, _structure_statement, %Entry{} = entry) do
    exec_statement(
      state,
      entry_statement,
      [
        entry.id,
        entry.path,
        subject_key(entry.subject),
        blob(entry.type),
        subtype_key(entry.subtype),
        block_id_key(entry.block_id),
        blob(entry)
      ]
    )
  end

  defp affected_paths(updated_entries, paths_to_clear) do
    updated_entries
    |> Enum.map(& &1.path)
    |> Kernel.++(paths_to_clear)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp delete_entries_for_paths(%State{}, []), do: {:ok, []}

  defp delete_entries_for_paths(%State{} = state, paths) do
    with {:ok, rows} <-
           query(
             state,
             "DELETE FROM entries WHERE path IN (#{placeholders(paths)}) RETURNING id",
             paths
           ) do
      {:ok, rows |> List.flatten() |> Enum.reject(&is_nil/1)}
    end
  end

  defp delete_structures_for_paths(%State{}, []), do: :ok

  defp delete_structures_for_paths(%State{} = state, paths) do
    exec(state, "DELETE FROM structures WHERE path IN (#{placeholders(paths)})", paths)
  end

  defp query_entries(%State{} = state, where, args) do
    query(state, "SELECT entry FROM entries #{where}", args)
  end

  defp entries_result({:ok, rows}) do
    Enum.map(rows, fn [entry_blob] -> decode_term(entry_blob) end)
  end

  defp entries_result({:error, _} = error), do: error

  defp constraints(initial_clauses, initial_args, type, subtype) do
    {clauses, args} = add_type_constraint(initial_clauses, initial_args, type)
    {clauses, args} = add_subtype_constraint(clauses, args, subtype)
    {Enum.join(Enum.reverse(clauses), " AND "), args}
  end

  defp where_clause(""), do: ""
  defp where_clause(where), do: "WHERE #{where}"

  defp placeholders(values), do: Enum.map_join(values, ", ", fn _ -> "?" end)

  defp subject_constraint(:_), do: {[], []}
  defp subject_constraint(subject), do: {["subject = ?"], [subject_key(subject)]}

  defp prefix_constraint(:_), do: {[], []}

  defp prefix_constraint(prefix) do
    {["subject LIKE ? ESCAPE '\\'"], [like_prefix(subject_key(prefix))]}
  end

  defp add_type_constraint(clauses, args, :_), do: {clauses, args}

  defp add_type_constraint(clauses, args, value),
    do: {["type = ?" | clauses], args ++ [blob(value)]}

  defp add_subtype_constraint(clauses, args, :_), do: {clauses, args}

  defp add_subtype_constraint(clauses, args, value),
    do: {["subtype = ?" | clauses], args ++ [subtype_key(value)]}

  defp transaction(%State{} = state, fun) do
    with :ok <- exec(state, "BEGIN IMMEDIATE") do
      case fun.() do
        :ok ->
          commit_transaction(state, :ok)

        {:ok, _} = result ->
          commit_transaction(state, result)

        {:error, _} = error ->
          exec(state, "ROLLBACK")
          error
      end
    end
  end

  defp commit_transaction(%State{} = state, result) do
    case exec(state, "COMMIT") do
      :ok ->
        result

      {:error, _} = error ->
        exec(state, "ROLLBACK")
        error
    end
  end

  defp sync_database(%State{conn: nil}), do: :ok
  defp sync_database(%State{}), do: :ok

  defp close_database(%State{conn: nil}), do: :ok
  defp close_database(%State{conn: conn}), do: Exqlite.Basic.close(conn)

  defp remove_database_root(%State{} = state) do
    case File.rm_rf(root_path(state.project, state.runtime_versions)) do
      {:ok, _paths} -> :ok
      {:error, reason, path} -> {:error, {reason, path}}
    end
  end

  defp reset_database_file(%State{} = state) do
    with :ok <- close_database(state),
         :ok <- remove_database_files(state),
         :ok <- ensure_database_directory(state),
         {:ok, conn} <- Exqlite.Basic.open(state.database_path) do
      state = %State{state | conn: conn}

      case initialize_schema(state) do
        {:ok, status} -> {{:ok, status}, state}
        {:error, _} = error -> {error, state}
      end
    else
      {:error, _} = error -> {error, %State{state | conn: nil}}
    end
  end

  defp remove_database_files(%State{} = state) do
    state.database_path
    |> database_files()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {reason, path}}}
      end
    end)
  end

  defp database_files(database_path) do
    [database_path, database_path <> "-wal", database_path <> "-shm"]
  end

  defp ensure_database_directory(%State{} = state) do
    directory = Path.dirname(state.database_path)

    case File.mkdir_p(directory) do
      :ok -> :ok
      {:error, :eexist} -> if File.dir?(directory), do: :ok, else: {:error, {:eexist, directory}}
      {:error, reason} -> {:error, {reason, directory}}
    end
  end

  defp recoverable_database_error?(%{__struct__: Exqlite.Error, message: message}) do
    message in ["database disk image is malformed", "file is not a database"]
  end

  defp recoverable_database_error?(_reason), do: false

  defp exec(%State{} = state, statement, args \\ []) do
    case Exqlite.Basic.exec(state.conn, statement, args) do
      {:error, reason, _details} -> {:error, reason}
      result -> rows_to_ok(result)
    end
  end

  defp query(%State{} = state, statement, args \\ []) do
    case Exqlite.Basic.exec(state.conn, statement, args) do
      {:error, reason, _details} -> {:error, reason}
      result -> rows(result)
    end
  end

  defp with_prepared_statements(%State{} = state, statements, callback) do
    case prepare_statements(state, statements) do
      {:ok, prepared_statements} ->
        result = callback.(prepared_statements)
        Enum.each(prepared_statements, &release_statement(state, &1))
        result

      {:error, _} = error ->
        error
    end
  end

  defp prepare_statements(%State{} = state, statements) do
    result =
      Enum.reduce_while(statements, {:ok, []}, fn statement, {:ok, prepared_statements} ->
        case prepare_statement(state, statement) do
          {:ok, prepared_statement} ->
            {:cont, {:ok, [prepared_statement | prepared_statements]}}

          {:error, _} = error ->
            Enum.each(prepared_statements, &release_statement(state, &1))
            {:halt, error}
        end
      end)

    case result do
      {:ok, prepared_statements} -> {:ok, Enum.reverse(prepared_statements)}
      {:error, _} = error -> error
    end
  end

  defp prepare_statement(%State{conn: %{db: database}}, statement) do
    case Sqlite3.prepare(database, statement) do
      {:ok, prepared_statement} -> {:ok, prepared_statement}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exec_statement(%State{conn: %{db: database}}, statement, args) do
    with :ok <- Sqlite3.bind(statement, args) do
      result =
        case Sqlite3.step(database, statement) do
          :done -> :ok
          {:error, reason} -> {:error, reason}
          :busy -> {:error, "Database busy"}
        end

      :ok = Sqlite3.reset(statement)
      result
    end
  end

  defp release_statement(%State{conn: %{db: database}}, statement),
    do: Sqlite3.release(database, statement)

  defp rows_to_ok(result) do
    case Exqlite.Basic.rows(result) do
      {:ok, _rows, _columns} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp rows(result) do
    case Exqlite.Basic.rows(result) do
      {:ok, rows, _columns} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  defp child_path(structure, child_id) do
    path =
      Enum.reduce_while(structure, [], fn
        {^child_id, _children}, children ->
          {:halt, [child_id | children]}

        {_, children}, path when map_size(children) == 0 ->
          {:cont, path}

        {current_id, children}, path ->
          case child_path(children, child_id) do
            {:ok, child_path} -> {:halt, [current_id | path] ++ Enum.reverse(child_path)}
            :error -> {:cont, path}
          end
      end)

    case path do
      [] -> :error
      path -> {:ok, Enum.reverse(path)}
    end
  end

  defp find_first_by_block_id(%State{} = state, block_ids) do
    Enum.reduce_while(block_ids, :error, fn block_id, failure ->
      case do_find_by_ids(state, [block_id], :_, :_) do
        [entry] -> {:halt, {:ok, entry}}
        {:error, _} = error -> {:halt, error}
        _ -> {:cont, failure}
      end
    end)
  end

  defp like_prefix(prefix) do
    prefix
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
    |> Kernel.<>("%")
  end

  defp subject_key(:_), do: :_
  defp subject_key(subject) when is_binary(subject), do: subject
  defp subject_key(subject) when is_atom(subject), do: inspect(subject)
  defp subject_key(subject) when is_list(subject), do: List.to_string(subject)
  defp subject_key(subject), do: inspect(subject)

  defp subtype_key(subtype), do: Atom.to_string(subtype)

  defp block_id_key(:root), do: 0
  defp block_id_key(block_id) when is_integer(block_id), do: block_id

  defp blob(term), do: {:blob, encode_term(term)}

  defp encode_term(term), do: :erlang.term_to_binary(term)
  defp decode_term(binary), do: :erlang.binary_to_term(binary)

  defp same_block_type?(left_entry, right_entry),
    do: Entry.is_block(left_entry) == Entry.is_block(right_entry)

  defp runtime_versions(%Project{} = project, opts) do
    Keyword.get_lazy(opts, :runtime_versions, fn -> EngineApi.runtime_versions(project) end)
  end
end
