defmodule Expert.Project.Diagnostics.State do
  alias Forge.Document
  alias Forge.Plugin.V1.Diagnostic
  alias Forge.Project

  require Logger

  defmodule Entry do
    defstruct build_number: 0, diagnostics: []

    def new(build_number) when is_integer(build_number) do
      %__MODULE__{build_number: build_number}
    end

    def new(build_number, diagnostic) do
      %__MODULE__{build_number: build_number, diagnostics: MapSet.new([diagnostic])}
    end

    def add(%__MODULE__{} = entry, build_number, diagnostic) do
      cond do
        build_number < entry.build_number ->
          entry

        build_number > entry.build_number ->
          new(build_number, diagnostic)

        true ->
          %__MODULE__{entry | diagnostics: MapSet.put(entry.diagnostics, diagnostic)}
      end
    end

    def diagnostics(%__MODULE__{} = entry) do
      Enum.to_list(entry.diagnostics)
    end
  end

  defstruct project: nil, entries_by_uri: %{}

  def new(%Project{} = project) do
    %__MODULE__{project: project}
  end

  def get(%__MODULE__{} = state, source_uri) do
    entry = Map.get(state.entries_by_uri, source_uri, Entry.new(0))
    Entry.diagnostics(entry)
  end

  def clear(%__MODULE__{} = state, source_uri) do
    new_entries = Map.put(state.entries_by_uri, source_uri, Entry.new(0))

    %__MODULE__{state | entries_by_uri: new_entries}
  end

  @doc """
  Only clear diagnostics if they've been synced to disk
  It's possible that the diagnostic presented by typing is still correct, and the file
  that exists on the disk is actually an older copy of the file in memory.
  """
  def clear_all_flushed(%__MODULE__{} = state) do
    cleared =
      Map.new(state.entries_by_uri, fn {uri, %Entry{} = entry} ->
        with true <- Document.Store.open?(uri),
             {:ok, %Document{} = document} <- Document.Store.fetch(uri),
             true <- keep_diagnostics?(document) do
          {uri, entry}
        else
          _ ->
            {uri, Entry.new(0)}
        end
      end)

    %__MODULE__{state | entries_by_uri: cleared}
  end

  def add(%__MODULE__{} = state, build_number, %Diagnostic.Result{} = diagnostic) do
    entries_by_uri =
      Map.update(
        state.entries_by_uri,
        diagnostic.uri,
        Entry.new(build_number, diagnostic),
        fn entry ->
          Entry.add(entry, build_number, diagnostic)
        end
      )

    %__MODULE__{state | entries_by_uri: entries_by_uri}
  end

  def add(%__MODULE__{} = state, _build_number, other) do
    Logger.error("Invalid diagnostic: #{inspect(other)}")
    state
  end

  defp keep_diagnostics?(%Document{} = document) do
    # Keep any diagnostics for script files, which aren't compiled)
    # or dirty files, which have been modified after compilation has occurrend
    document.dirty? or script_file?(document)
  end

  defp script_file?(document) do
    Path.extname(document.path) == ".exs"
  end
end
