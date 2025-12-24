defmodule Forge.Namespace.FileSync do
  defmodule Classification do
    defstruct changed: [],
              new: [],
              deleted: []
  end

  alias __MODULE__.Classification

  @doc """
  Classifies files into changed, new, and deleted categories.

  It looks at `**/ebin/*` files in both the base directory and output directory,
  applying namespacing to the file names in the output directory.
  Files can be `.beam` or `.app` files.

  Then compares the mtimes of the files to determine their classification.

  If files in output_directory are not present in base_directory, they are classified as deleted.
  """
  def classify_files(same, same),
    do: %Classification{
      changed: [],
      new: [],
      deleted: []
    }

  def classify_files(base_directory, output_directory) do
    # Files in base directory are not namespaced, eg:
    # lib/foo/ebin/Elixir.Foo.Bar.beam
    # lib/foo/ebin/foo.app
    #
    # Files in output directory are namespaced, eg:
    # lib/xp_foo/ebin/Elixir.XPFoo.Bar.beam
    # lib/xp_foo/ebin/xp_foo.app
    #
    # We need to compare the files by applying namespacing to the base directory paths,
    # then comparing mtimes.
    #
    # For any files in output_directory that don't have a corresponding file in base_directory,
    # we classify them as deleted.

    base_files = find_files(Path.join(base_directory, "lib"))
    output_files = find_files(Path.join(output_directory, "lib"))

    base_map =
      Enum.reduce(base_files, %{}, fn base_file, acc ->
        relative_path = Path.relative_to(base_file, base_directory)

        namespaced_relative_path =
          relative_path
          |> Forge.Namespace.Path.apply()
          |> maybe_namespace_filename()

        dest_path = Path.join(output_directory, namespaced_relative_path)
        Map.put(acc, base_file, dest_path)
      end)

    expected_dest_files = base_map |> Map.values() |> MapSet.new()
    output_set = MapSet.new(output_files)

    classification =
      Enum.reduce(base_map, %Classification{}, fn {base_file, dest_path}, acc ->
        if File.exists?(dest_path) do
          base_mtime = File.stat!(base_file).mtime
          output_mtime = File.stat!(dest_path).mtime

          if base_mtime > output_mtime do
            %{acc | changed: [{base_file, dest_path} | acc.changed]}
          else
            acc
          end
        else
          %{acc | new: [{base_file, dest_path} | acc.new]}
        end
      end)

    deleted_files =
      output_set
      |> MapSet.difference(MapSet.new(expected_dest_files))
      |> MapSet.to_list()

    %{classification | deleted: deleted_files}
  end

  defp find_files(directory) do
    [directory, "**", "*"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end

  defp maybe_namespace_filename(file_path) do
    # namespace filename for .beam and .app files
    extname = Path.extname(file_path)

    if extname in [".beam", ".app"] do
      dirname = Path.dirname(file_path)
      basename = Path.basename(file_path, extname)

      namespaced_basename =
        basename
        |> String.to_atom()
        |> Forge.Namespace.Module.apply()
        |> Atom.to_string()

      Path.join(dirname, namespaced_basename <> extname)
    else
      file_path
    end
  end
end
