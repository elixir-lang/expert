defmodule Engine.Search.Store.Backends.Sqlite.State do
  alias Forge.Project
  alias Forge.Search.Indexer.Entry
  alias Forge.VM.Versions

  import Entry, only: :macros

  @version 1

  def db_directory(%Project{} = project) do
    versions = Versions.current()
    workspace_path = Project.workspace_path(project, ["indexes", Project.name(project), "sqlite"])

    Path.join([workspace_path, versions.erlang, versions.elixir])
  end

  def db_file(%Project{} = project) do
    project
    |> db_directory()
    |> Path.join("db.sqlite3")
  end

  def prepare(conn) do
    query(
      conn,
      ~S"""
      CREATE TABLE IF NOT EXISTS schema (
        id integer PRIMARY KEY,
        version integer NOT NULL DEFAULT 1,
        inserted_at text NOT NULL DEFAULT CURRENT_TIMESTASMP
      );
      """,
      []
    )

    query(conn, ~S"PRAGMA synchronous = OFF", [])

    case query(conn, ~S"SELECT MAX(version) FROM schema;", []) do
      [[version]] when version == @version ->
        {:ok, :stale}

      _result ->
        query(conn, ~S"INSERT INTO schema (version) VALUES (?);", [@version])

        query(conn, ~S"DROP TABLE IF EXISTS entries", [])

        query(
          conn,
          ~S"""
          CREATE TABLE IF NOT EXISTS entries (
            id integer PRIMARY KEY,
            application text,
            subject text,
            block_id integer,
            block_range text,
            path text,
            range text,
            subtype text,
            type text,
            metadata text
          );
          """,
          []
        )

        {:ok, :empty}
    end
  end

  def reduce(conn, acc, reducer_fun) do
    rows = query(conn, ~S"SELECT * FROM entries", [])
    entries = Enum.map(rows, &from_db/1)

    Enum.reduce(entries, acc, reducer_fun)
  end

  def replace_all(conn, entries) do
    query(conn, ~S"DELETE FROM entries", [])

    for entry <- entries do
      {query, args} = to_db_insert(entry)
      query(conn, query, args)
    end

    :ok
  end

  def insert(conn, entries) do
    for entry <- entries do
      {query, args} = to_db_insert(entry)
      query(conn, query, args)
    end

    :ok
  end

  def drop(conn) do
    query(conn, ~S"DELETE FROM entries", [])
    true
  end

  def destroy(conn, project) do
    Exqlite.Basic.close(conn)
    File.rm_rf!(db_file(project))
  end

  def structure_for_path(conn, path) do
    result =
      query(
        conn,
        ~S"SELECT * FROM entries WHERE subtype = 'block_structure' AND path = ? LIMIT 1",
        [path]
      )

    case result do
      [] ->
        :error

      [db_entry] ->
        entry = from_db(db_entry)

        {:ok, entry.subject}
    end
  end

  def delete_by_path(conn, path) do
    result = query(conn, ~S"DELETE FROM entries WHERE path = ? RETURNING id", [path])
    {:ok, List.flatten(result)}
  end

  def find_by_id(conn, id) do
    result = query(conn, ~s"SELECT * FROM entries WHERE id = ? LIMIT 1", [id])

    case result do
      [entry] ->
        {:ok, from_db(entry)}

      _ ->
        :error
    end
  end

  def find_by_ids(conn, ids, type_query, subtype_query) do
    type_binary = :erlang.term_to_binary(type_query)
    subtype_binary = to_string(subtype_query)

    ids_query = "(" <> Enum.map_join(ids, ",", fn _ -> "?" end) <> ")"

    result =
      query(
        conn,
        ~s"SELECT * FROM entries WHERE id IN #{ids_query} and type = ? and subtype = ?",
        ids ++ [type_binary, subtype_binary]
      )

    Enum.map(result, &from_db/1)
  end

  def find_by_subject(conn, subject, type, subtype) do
    args = []
    {subject_query, args} =
      case subject do
        :_ -> {"TRUE", args}
        _ -> {"subject = ?", args ++ [cast_subject(Module.concat([subject]))]}
      end
    {type_query, args} =
      case type do
        :_ -> {"TRUE", args}
        _ -> {"type = ?", args ++ [:erlang.term_to_binary(type)]}
      end
    subtype_query = to_string(subtype)

    result = query(conn, ~s"SELECT * FROM entries WHERE #{subject_query} AND #{type_query} AND subtype = ?", args ++ [subtype_query])

    Enum.map(result, &from_db/1)
  end

  def find_by_prefix(conn, subject, type, subtype) do
    <<_, _tag, _size, prefix::binary>> = cast_subject(Module.concat([subject]))
    type = :erlang.term_to_binary(type)
    subtype = to_string(subtype)


    result =
      query(conn, ~S"SELECT * FROM entries WHERE subject LIKE '%' || ? || '%'", [prefix])

    Enum.map(result, &from_db/1)
  end

  def parent(conn, %Entry{} = entry) do
    with {:ok, structure} <- structure_for_path(conn, entry.path),
         {:ok, child_path} <- child_path(structure, entry.block_id) do
      child_path =
        if is_block(entry) do
          # if we're a block, finding the first block will find us, so pop
          # our id off the path.
          tl(child_path)
        else
          child_path
        end

      find_first_by_block_id(conn, child_path)
    end
  end

  def siblings(conn, %Entry{} = entry) do
    block_id = cast_block_id(entry.block_id)

    entries =
      conn
      |> query(~S"SELECT DISTINCT * FROM entries WHERE block_id = ? AND path = ?ORDER BY id ASC", [block_id, entry.path])
      |> Enum.map(&from_db/1)
      |> Enum.filter(fn sibling ->
        case {is_block(entry), is_block(sibling)} do
          {same, same} -> true
          _ -> false
        end
      end)

    {:ok, entries}
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

  defp find_first_by_block_id(conn, block_ids) do
    Enum.reduce_while(block_ids, :error, fn block_id, failure ->
      case find_by_id(conn, block_id) do
        {:ok, _} = success ->
          {:halt, success}

        _ ->
          {:cont, failure}
      end
    end)
  end

  defp to_db_insert(%Entry{} = entry) do
    query =
      ~S"""
      INSERT INTO entries (id, application, subject, block_id, block_range, path, range, subtype, type, metadata)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """

    values =
      [
        entry.id,
        to_string(entry.application),
        cast_subject(entry.subject),
        cast_block_id(entry.block_id),
        :erlang.term_to_binary(entry.block_range),
        entry.path,
        :erlang.term_to_binary(entry.range),
        to_string(entry.subtype),
        :erlang.term_to_binary(entry.type),
        :erlang.term_to_binary(entry.metadata)
      ]

    {query, values}
  end

  defp cast_block_id(:root), do: -1
  defp cast_block_id(nil), do: nil
  defp cast_block_id(id) when is_integer(id), do: id

  defp load_block_id(-1), do: :root
  defp load_block_id(id), do: id

  defp load_application(""), do: nil
  defp load_application(application), do: String.to_existing_atom(application)

  defp cast_subject(subject) do
    :erlang.term_to_binary(subject, [:deterministic, compressed: 0])
  end

  defp load_subject(subject) do
    :erlang.binary_to_term(subject)
  end

  defp from_db([
         id,
         application,
         subject,
         block_id,
         block_range,
         path,
         range,
         subtype,
         type,
         metadata
       ]) do
    %Entry{
      id: id,
      application: load_application(application),
      subject: load_subject(subject),
      block_id: load_block_id(block_id),
      block_range: :erlang.binary_to_term(block_range),
      path: path,
      range: :erlang.binary_to_term(range),
      subtype: String.to_existing_atom(subtype),
      type: :erlang.binary_to_term(type),
      metadata: :erlang.binary_to_term(metadata)
    }
  end

  defp query(conn, stmt, args) do
    args = Enum.map(args, &cast/1)

    case Exqlite.Basic.exec(conn, stmt, args) do
      {:error, %{message: message}} ->
        {:error, message}

      result ->
        case Exqlite.Basic.rows(result) do
          {:ok, rows, _} -> rows
          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp cast(arg) do
    if is_atom(arg) and String.starts_with?(to_string(arg), "Elixir.") do
      Macro.to_string(arg)
    else
      arg
    end
  end
end
