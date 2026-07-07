defmodule Engine.Search.Indexer.Manifest do
  @moduledoc """
  Registry of indexed input files used to plan incremental indexing.
  """

  alias Engine.Search.Indexer.Paths

  defmodule Entry do
    @moduledoc false

    defstruct [
      :input_path,
      :output_path,
      :kind,
      :mtime,
      :size,
      :source_path,
      :source_mtime,
      :source_size
    ]

    @type kind :: :source | :beam
    @type file_time :: :calendar.datetime() | integer()

    @type t :: %__MODULE__{
            input_path: Path.t(),
            output_path: Path.t() | nil,
            kind: kind(),
            mtime: file_time() | nil,
            size: non_neg_integer() | nil,
            source_path: Path.t() | nil,
            source_mtime: file_time() | nil,
            source_size: non_neg_integer() | nil
          }

    def source(path) when is_binary(path) do
      from_file(path, path, :source)
    end

    def dirty_source(path) when is_binary(path) do
      # Dirty source entries come from editor-buffer compiles, so they must not
      # match the current disk file stat during incremental index planning.
      {:ok,
       %__MODULE__{
         input_path: path,
         output_path: path,
         kind: :source,
         mtime: nil,
         size: nil
       }}
    end

    def beam(path, output_path) when is_binary(path) and is_binary(output_path) do
      with {:ok, entry} <- from_file(path, output_path, :beam),
           {:ok, source_stat} <- File.stat(output_path) do
        {:ok,
         %__MODULE__{
           entry
           | source_path: output_path,
             source_mtime: source_stat.mtime,
             source_size: source_stat.size
         }}
      end
    end

    def beam(path, output_path, %File.Stat{} = beam_stat, {:ok, %File.Stat{} = source_stat})
        when is_binary(path) and is_binary(output_path) do
      {:ok,
       %__MODULE__{
         input_path: path,
         output_path: output_path,
         kind: :beam,
         mtime: beam_stat.mtime,
         size: beam_stat.size,
         source_path: output_path,
         source_mtime: source_stat.mtime,
         source_size: source_stat.size
       }}
    end

    def beam(_path, _output_path, %File.Stat{}, :error), do: :error

    def skipped_beam(path, source_path \\ nil) when is_binary(path) do
      with {:ok, entry} <- from_file(path, nil, :beam) do
        {:ok, put_source_snapshot(entry, source_path)}
      end
    end

    def skipped_beam(
          path,
          source_path,
          %File.Stat{} = beam_stat,
          {:ok, %File.Stat{} = source_stat}
        )
        when is_binary(path) and is_binary(source_path) do
      {:ok,
       %__MODULE__{
         input_path: path,
         output_path: nil,
         kind: :beam,
         mtime: beam_stat.mtime,
         size: beam_stat.size,
         source_path: source_path,
         source_mtime: source_stat.mtime,
         source_size: source_stat.size
       }}
    end

    def skipped_beam(path, source_path, %File.Stat{} = beam_stat, :error)
        when is_binary(path) and is_binary(source_path) do
      {:ok,
       %__MODULE__{
         input_path: path,
         output_path: nil,
         kind: :beam,
         mtime: beam_stat.mtime,
         size: beam_stat.size,
         source_path: source_path
       }}
    end

    def skipped_beam(path, _source_path, %File.Stat{} = beam_stat, _source_stat_result)
        when is_binary(path) do
      {:ok,
       %__MODULE__{
         input_path: path,
         output_path: nil,
         kind: :beam,
         mtime: beam_stat.mtime,
         size: beam_stat.size
       }}
    end

    def matches_file?(%__MODULE__{} = entry) do
      matches_input_file?(entry) and matches_source_file?(entry)
    end

    defp from_file(path, output_path, kind) do
      case File.stat(path) do
        {:ok, %File.Stat{} = stat} ->
          {:ok, from_stat(path, output_path, kind, stat)}

        _ ->
          :error
      end
    end

    defp from_stat(path, output_path, kind, %File.Stat{} = stat) do
      %__MODULE__{
        input_path: path,
        output_path: output_path,
        kind: kind,
        mtime: stat.mtime,
        size: stat.size
      }
    end

    defp put_source_snapshot(%__MODULE__{} = entry, source_path) when is_binary(source_path) do
      case File.stat(source_path) do
        {:ok, %File.Stat{} = stat} ->
          %__MODULE__{
            entry
            | source_path: source_path,
              source_mtime: stat.mtime,
              source_size: stat.size
          }

        _ ->
          %__MODULE__{entry | source_path: source_path}
      end
    end

    defp put_source_snapshot(%__MODULE__{} = entry, _source_path), do: entry

    defp matches_input_file?(%__MODULE__{input_path: path, mtime: mtime, size: size}) do
      case File.stat(path) do
        {:ok, %File.Stat{mtime: ^mtime, size: ^size}} -> true
        _ -> false
      end
    end

    defp matches_source_file?(%__MODULE__{source_path: nil}), do: true

    defp matches_source_file?(%__MODULE__{
           source_path: path,
           source_mtime: nil,
           source_size: nil
         }) do
      match?({:error, _}, File.stat(path))
    end

    defp matches_source_file?(%__MODULE__{
           source_path: path,
           source_mtime: mtime,
           source_size: size
         }) do
      case File.stat(path) do
        {:ok, %File.Stat{mtime: ^mtime, size: ^size}} -> true
        _ -> false
      end
    end
  end

  defmodule Plan do
    @moduledoc false

    defstruct source_paths_to_index: [],
              beam_paths_to_index: [],
              input_paths_to_remove: [],
              output_paths_to_clear: []
  end

  defstruct entries_by_input_path: %{}

  @type t :: %__MODULE__{entries_by_input_path: %{Path.t() => Entry.t()}}

  def new(entries \\ []) when is_list(entries) do
    Enum.reduce(entries, %__MODULE__{}, &put/2)
  end

  def entries(%__MODULE__{} = manifest) do
    Map.values(manifest.entries_by_input_path)
  end

  def fetch(%__MODULE__{} = manifest, input_path) do
    Map.fetch(manifest.entries_by_input_path, input_path)
  end

  def plan(%__MODULE__{} = manifest, %Paths{} = paths) do
    source_paths = MapSet.new(paths.source_paths)
    beam_paths = MapSet.new(paths.beam_paths)
    current_paths = MapSet.union(source_paths, beam_paths)
    known_paths = manifest.entries_by_input_path |> Map.keys() |> MapSet.new()

    {source_paths_to_index, beam_paths_to_index, dirty_outputs, input_paths_to_remove,
     output_paths_to_clear} =
      manifest
      |> entries()
      |> Enum.reduce({[], [], MapSet.new(), [], MapSet.new()}, fn entry, acc ->
        plan_entry(entry, source_paths, beam_paths, current_paths, acc)
      end)

    new_source_paths =
      source_paths
      |> MapSet.difference(known_paths)
      |> Enum.reject(&empty_file?/1)

    new_beam_paths = beam_paths |> MapSet.difference(known_paths) |> Enum.to_list()

    beam_paths_to_index =
      beam_paths_to_index
      |> include_known_beams_for_dirty_outputs(manifest, beam_paths, dirty_outputs)
      |> Enum.concat(new_beam_paths)
      |> Enum.uniq()

    %Plan{
      source_paths_to_index: Enum.uniq(source_paths_to_index ++ new_source_paths),
      beam_paths_to_index: beam_paths_to_index,
      input_paths_to_remove: Enum.uniq(input_paths_to_remove),
      output_paths_to_clear: output_paths_to_clear |> MapSet.to_list()
    }
  end

  def apply_update(%__MODULE__{} = manifest, %Plan{} = plan, entries) when is_list(entries) do
    indexed_input_paths = plan.source_paths_to_index ++ plan.beam_paths_to_index
    paths_to_remove = plan.input_paths_to_remove ++ indexed_input_paths

    manifest
    |> remove(paths_to_remove)
    |> put_all(entries)
  end

  def replace_output(%__MODULE__{} = manifest, output_path, entries)
      when is_binary(output_path) and is_list(entries) do
    %__MODULE__{
      manifest
      | entries_by_input_path:
          Map.reject(manifest.entries_by_input_path, fn {_input_path, entry} ->
            entry_for_output?(entry, output_path)
          end)
    }
    |> put_all(entries)
  end

  def replace_outputs(%__MODULE__{} = manifest, entries_by_output)
      when is_map(entries_by_output) do
    Enum.reduce(entries_by_output, manifest, fn {output_path, entries}, manifest ->
      replace_output(manifest, output_path, entries)
    end)
  end

  def output_path(%Entry{output_path: output_path}) when is_binary(output_path), do: output_path
  def output_path(%Entry{source_path: source_path}) when is_binary(source_path), do: source_path
  def output_path(%Entry{kind: :source, input_path: input_path}), do: input_path
  def output_path(%Entry{}), do: nil

  def paths(%Entry{} = entry) do
    [entry.input_path, entry.output_path, entry.source_path]
    |> Enum.reject(&is_nil/1)
  end

  def output_paths_to_clear(%__MODULE__{} = manifest, %Plan{} = plan, entries)
      when is_list(entries) do
    indexed_input_paths = plan.source_paths_to_index ++ plan.beam_paths_to_index
    old_outputs = output_paths_for_inputs(manifest, indexed_input_paths)
    new_outputs = output_paths(entries)

    old_outputs
    |> MapSet.union(MapSet.new(plan.output_paths_to_clear))
    |> MapSet.difference(new_outputs)
    |> Enum.to_list()
  end

  def output_paths(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(fn
      %Entry{output_path: output_path} when is_binary(output_path) -> [output_path]
      _entry -> []
    end)
    |> MapSet.new()
  end

  defp plan_entry(
         %Entry{input_path: input_path} = entry,
         source_paths,
         beam_paths,
         current_paths,
         {source_to_index, beam_to_index, dirty_outputs, remove_inputs, clear_outputs}
       ) do
    cond do
      not MapSet.member?(current_paths, input_path) ->
        {source_to_index, beam_to_index, put_output(dirty_outputs, entry),
         [input_path | remove_inputs], put_output(clear_outputs, entry)}

      source_entry?(entry, source_paths) ->
        if Entry.matches_file?(entry) do
          {source_to_index, beam_to_index, dirty_outputs, remove_inputs, clear_outputs}
        else
          {[input_path | source_to_index], beam_to_index, put_output(dirty_outputs, entry),
           remove_inputs, clear_outputs}
        end

      beam_entry?(entry, beam_paths) ->
        if Entry.matches_file?(entry) do
          {source_to_index, beam_to_index, dirty_outputs, remove_inputs, clear_outputs}
        else
          {source_to_index, [input_path | beam_to_index], put_output(dirty_outputs, entry),
           remove_inputs, clear_outputs}
        end

      MapSet.member?(source_paths, input_path) ->
        {[input_path | source_to_index], beam_to_index, put_output(dirty_outputs, entry),
         remove_inputs, clear_outputs}

      MapSet.member?(beam_paths, input_path) ->
        {source_to_index, [input_path | beam_to_index], put_output(dirty_outputs, entry),
         remove_inputs, clear_outputs}
    end
  end

  defp source_entry?(%Entry{kind: :source, input_path: input_path}, source_paths) do
    MapSet.member?(source_paths, input_path)
  end

  defp source_entry?(_entry, _source_paths), do: false

  defp beam_entry?(%Entry{kind: :beam, input_path: input_path}, beam_paths) do
    MapSet.member?(beam_paths, input_path)
  end

  defp beam_entry?(_entry, _beam_paths), do: false

  defp include_known_beams_for_dirty_outputs(
         beam_paths_to_index,
         manifest,
         beam_paths,
         dirty_outputs
       ) do
    dirty_beam_paths =
      for %Entry{kind: :beam, input_path: input_path, output_path: output_path} <-
            entries(manifest),
          is_binary(output_path),
          MapSet.member?(beam_paths, input_path),
          MapSet.member?(dirty_outputs, output_path) do
        input_path
      end

    Enum.uniq(beam_paths_to_index ++ dirty_beam_paths)
  end

  defp entry_for_output?(%Entry{} = entry, output_path) do
    output_path in [entry.input_path, entry.output_path, entry.source_path]
  end

  defp output_paths_for_inputs(%__MODULE__{} = manifest, input_paths) do
    input_paths
    |> Enum.flat_map(fn input_path ->
      case fetch(manifest, input_path) do
        {:ok, %Entry{output_path: output_path}} when is_binary(output_path) -> [output_path]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp put_all(%__MODULE__{} = manifest, entries) do
    Enum.reduce(entries, manifest, &put/2)
  end

  defp put(%Entry{input_path: input_path} = entry, %__MODULE__{} = manifest) do
    %__MODULE__{
      manifest
      | entries_by_input_path: Map.put(manifest.entries_by_input_path, input_path, entry)
    }
  end

  defp remove(%__MODULE__{} = manifest, input_paths) do
    %__MODULE__{
      manifest
      | entries_by_input_path: Map.drop(manifest.entries_by_input_path, input_paths)
    }
  end

  defp put_output(outputs, %Entry{output_path: output_path}) when is_binary(output_path) do
    MapSet.put(outputs, output_path)
  end

  defp put_output(outputs, _entry), do: outputs

  defp empty_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: 0}} -> true
      _ -> false
    end
  end
end
