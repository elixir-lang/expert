defmodule Engine.CodeMod.Format.Cache do
  @moduledoc """
  A read-through cache of formatters, keyed by file path.

  Two public ETS tables are used:

  - `entries` — one row per unique `{opts, extension}` combination, keyed by a
    generated entry ID. Stores the `Entry` struct once, shared across all files
    that resolve to the same config.

  - `paths` — one row per cached file path, keyed by path. Stores only the
    entry ID so the formatter data is never duplicated.

  A lookup reads the path row to get the entry ID, then reads the entry row to
  get the formatter and opts. On a path miss the caller scans the entries table
  to find a matching entry (by extension and `:inputs` glob) without going to
  the GenServer; only a full entry miss requires a GenServer call to resolve.

  On a cadence, the known `.formatter.exs` files are checked for stat changes.
  When one is detected, both tables are cleared and entries re-resolve lazily.
  """

  use GenServer

  import Forge.Logging
  import Record

  alias Engine.CodeMod.Format
  alias Engine.CodeMod.Format.Resolver
  alias Forge.Document
  alias Forge.Project

  require Logger

  defmodule Entry do
    @moduledoc false

    defstruct [:id, :formatter, :opts, :extension, :path]
    @type id :: non_neg_integer()

    @type t :: %__MODULE__{
            id: id(),
            formatter: Engine.CodeMod.Format.formatter_function(),
            opts: keyword(),
            extension: String.t(),
            path: Path.t()
          }

    @spec new(Format.formatter_function(), keyword(), Path.t()) :: t()
    def new(formatter, opts, file_path) do
      extension = Path.extname(file_path)

      %__MODULE__{
        id: :erlang.unique_integer([:positive]),
        formatter: formatter,
        opts: opts,
        extension: extension,
        path: file_path
      }
    end

    @spec applies_to?(t(), Path.t()) :: boolean()
    def applies_to?(%__MODULE__{} = entry, file_path) do
      root = Keyword.get(entry.opts, :root)
      inputs = Keyword.get(entry.opts, :inputs)

      entry.extension == Path.extname(file_path) and
        is_binary(root) and
        is_list(inputs) and
        Enum.any?(inputs, fn glob ->
          PathGlob.match?(file_path, Path.join(root, glob), match_dot: true)
        end)
    end
  end

  # -- State -------------------------------------------------------------------

  defmodule State do
    @moduledoc false

    defstruct project: nil, refresh_interval: nil, dot_formatters: %{}

    @type dot_formatters :: %{Path.t() => File.Stat.t()}
    @type t :: %__MODULE__{
            project: Forge.Project.t(),
            refresh_interval: non_neg_integer(),
            dot_formatters: dot_formatters()
          }

    @spec new(Forge.Project.t(), non_neg_integer()) :: t()
    def new(%Forge.Project{} = project, refresh_interval) do
      %__MODULE__{project: project, refresh_interval: refresh_interval}
    end

    @spec put_dot_formatters(t(), dot_formatters()) :: t()
    def put_dot_formatters(%__MODULE__{} = state, dot_formatters) do
      %__MODULE__{state | dot_formatters: dot_formatters}
    end
  end

  # -- ETS tables --------------------------------------------------------------

  @entries_table :"#{__MODULE__}.Entries"
  @paths_table :"#{__MODULE__}.Paths"

  # keypos: 2 — records are {tag, field1, field2, ...} so field1 is at position 2
  @entries_table_opts [:named_table, :public, :set, read_concurrency: true, keypos: 2]
  @paths_table_opts [:named_table, :public, :set, read_concurrency: true, keypos: 2]

  @default_refresh_interval :timer.seconds(10)

  # -- Records (ETS row formats) -----------------------------------------------

  defrecordp :entry_row, id: nil, entry: nil
  defrecordp :path_row, path: nil, entry_id: nil

  @type entry_row :: record(:entry_row, id: Entry.id(), entry: Entry.t())
  @type path_row :: record(:path_row, path: Path.t(), entry_id: non_neg_integer())

  # -- Public API --------------------------------------------------------------

  @spec fetch_formatter(Project.t(), Path.t()) ::
          {:ok, Format.formatter_function(), keyword()} | :error
  def fetch_formatter(%Project{} = project, file_path) do
    with {:ok, entry_id} <- fetch_path(file_path),
         {:ok, entry} <- fetch_entry(entry_id) do
      Logger.debug("formatter cache hit for #{file_path}")
      {:ok, entry.formatter, entry.opts}
    else
      :error ->
        Logger.debug("formatter cache miss for #{file_path}")

        timed_log("formatter cache miss (call + resolve) for #{file_path}", fn ->
          case GenServer.call(__MODULE__, {:resolve, project, file_path}) do
            {:ok, %Entry{} = entry} ->
              {:ok, entry.formatter, entry.opts}

            :error ->
              :error
          end
        end)
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -- GenServer ---------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    :ets.new(@entries_table, @entries_table_opts)
    :ets.new(@paths_table, @paths_table_opts)
    project = Keyword.get_lazy(opts, :project, &Engine.get_project/0)
    interval = Keyword.get(opts, :refresh_interval, @default_refresh_interval)
    schedule_refresh(interval)

    {:ok, State.new(project, interval), {:continue, :discover_dot_formatters}}
  end

  @impl GenServer
  def handle_continue(:discover_dot_formatters, %State{} = state) do
    {:noreply, State.put_dot_formatters(state, discover_dot_formatters(state.project))}
  end

  @impl GenServer
  def handle_call({:resolve, %Project{} = project, file_path}, _from, %State{} = state) do
    {:reply, find_or_resolve(project, file_path), state}
  end

  @impl GenServer
  def handle_info(:refresh, %State{} = state) do
    new_state =
      if dot_formatters_changed?(state.dot_formatters) do
        dot_formatters =
          timed_log(".formatter.exs scan", fn ->
            discover_dot_formatters(state.project)
          end)

        Logger.info("formatter config changed, clearing cache")
        :ets.delete_all_objects(@entries_table)
        :ets.delete_all_objects(@paths_table)

        State.put_dot_formatters(state, dot_formatters)
      else
        state
      end

    clean_closed_entries()
    schedule_refresh(state.refresh_interval)

    {:noreply, new_state}
  end

  # -- Private -----------------------------------------------------------------

  @spec find_or_resolve(Project.t(), Path.t()) :: {:ok, Entry.t()} | :error
  defp find_or_resolve(%Project{} = project, file_path) do
    case fetch_path(file_path) do
      {:ok, entry_id} ->
        fetch_entry(entry_id)

      :error ->
        case find_matching_entry(file_path) do
          {:ok, %Entry{} = entry} ->
            :ets.insert(@paths_table, path_row(path: file_path, entry_id: entry.id))
            {:ok, entry}

          :error ->
            resolve_and_store(project, file_path)
        end
    end
  end

  @spec find_matching_entry(Path.t()) :: {:ok, Entry.t()} | :error
  defp find_matching_entry(file_path) do
    extension = Path.extname(file_path)

    @entries_table
    |> :ets.select([{entry_row(id: :_, entry: :_), [], [:"$_"]}])
    |> Enum.find_value(:error, fn
      entry_row(entry: %Entry{extension: ^extension} = entry) ->
        if Entry.applies_to?(entry, file_path) do
          {:ok, entry}
        end

      _ ->
        false
    end)
  end

  @spec resolve_and_store(Project.t(), Path.t()) :: {:ok, Entry.t()} | :error
  defp resolve_and_store(%Project{} = project, file_path) do
    {formatter, opts} = Resolver.resolve(project, file_path)
    entry = Entry.new(formatter, opts, file_path)

    true = :ets.insert(@entries_table, entry_row(id: entry.id, entry: entry))
    true = :ets.insert(@paths_table, path_row(path: file_path, entry_id: entry.id))

    {:ok, entry}
  rescue
    exception ->
      formatted_stack = Exception.format(:error, exception, __STACKTRACE__)
      Logger.warning(["Could not resolve formatter for ", file_path, ": ", formatted_stack])

      :error
  end

  @spec fetch_entry(Entry.id()) :: {:ok, Entry.t()} | :error
  defp fetch_entry(entry_id) do
    fetch(@entries_table, entry_id, entry_row(:entry))
  end

  @spec fetch_path(Path.t()) :: {:ok, Entry.id()} | :error
  defp fetch_path(file_path) do
    fetch(@paths_table, file_path, path_row(:entry_id))
  end

  @spec fetch(atom(), term(), non_neg_integer()) :: {:ok, term()} | :error
  defp fetch(table, key, field) do
    # Record field indices are 1-based from the first field; ETS positions are
    # also 1-based but include the record tag at position 1, so we add 1 to skip it.
    {:ok, :ets.lookup_element(table, key, field + 1)}
  rescue
    ArgumentError -> :error
  end

  @spec dot_formatters_changed?(State.dot_formatters()) :: boolean()
  defp dot_formatters_changed?(dot_formatters) do
    timed_log(".formatter.exs mtime check", fn ->
      Enum.any?(dot_formatters, fn {path, stored_stat} ->
        case File.stat(path, time: :posix) do
          {:ok, stat} -> stat != stored_stat
          {:error, _} -> true
        end
      end)
    end)
  end

  @spec discover_dot_formatters(Project.t()) :: State.dot_formatters()
  defp discover_dot_formatters(%Project{} = project) do
    case Project.root_path(project) do
      nil ->
        %{}

      root_path ->
        discover_dot_formatters_at_path(root_path, %{})
    end
  end

  @spec discover_dot_formatters_at_path(Path.t(), State.dot_formatters()) ::
          State.dot_formatters()
  defp discover_dot_formatters_at_path(dir, dot_formatters) do
    formatter_exs = Path.join(dir, ".formatter.exs")

    case File.stat(formatter_exs, time: :posix) do
      {:ok, stat} ->
        dot_formatters = Map.put(dot_formatters, formatter_exs, stat)

        formatter_exs
        |> subdirectories_from_formatter_config()
        |> Enum.reduce(dot_formatters, fn sub, acc ->
          discover_dot_formatters_at_path(sub, acc)
        end)

      {:error, _} ->
        dot_formatters
    end
  end

  @spec subdirectories_from_formatter_config(Path.t()) :: [Path.t()]
  defp subdirectories_from_formatter_config(formatter_exs) do
    {terms, _binding} = Code.eval_file(formatter_exs)
    subdirectories = Keyword.get(terms, :subdirectories) || []
    base_directory = Path.dirname(formatter_exs)

    Enum.flat_map(subdirectories, fn subdirectory ->
      base_directory
      |> Path.join(subdirectory)
      |> Path.wildcard()
    end)
  rescue
    _ -> []
  end

  @spec schedule_refresh(non_neg_integer()) :: reference()
  defp schedule_refresh(interval) do
    Process.send_after(self(), :refresh, interval)
  end

  defp clean_closed_entries do
    closed_entries =
      @entries_table
      |> :ets.tab2list()
      |> Enum.reject(fn entry_row(entry: %Entry{} = entry) ->
        entry.path
        |> Document.Path.to_uri()
        |> Document.Store.open?()
      end)

    Enum.each(closed_entries, fn entry_row(entry: %Entry{} = entry) ->
      true = :ets.delete(@entries_table, entry.id)
      true = :ets.delete(@paths_table, entry.path)
    end)
  end
end
