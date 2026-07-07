defmodule Engine.Search.Indexer.ManifestTest do
  use ExUnit.Case, async: true

  alias Engine.Search.Indexer.Manifest
  alias Engine.Search.Indexer.Manifest.Entry
  alias Engine.Search.Indexer.Paths

  @moduletag :tmp_dir

  describe "plan/2" do
    test "does not fan out from one new beam to all known beams", %{tmp_dir: tmp_dir} do
      beam_paths =
        [known_beam_1, known_beam_2, known_beam_3, new_beam_path] = beam_paths(tmp_dir, 4)

      Enum.each(beam_paths, &File.write!(&1, "beam"))

      manifest_entries =
        [known_beam_1, known_beam_2, known_beam_3]
        |> Enum.map(fn beam_path ->
          assert {:ok, entry} = Entry.skipped_beam(beam_path, nil)
          entry
        end)

      manifest = Manifest.new(manifest_entries)
      paths = %Paths{source_paths: [], beam_paths: beam_paths}

      assert %Manifest.Plan{beam_paths_to_index: [^new_beam_path]} =
               Manifest.plan(manifest, paths)
    end
  end

  describe "replace_output/3" do
    test "replaces beam entries tied to a source output with a source entry", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "source.ex")
      beam_path = Path.join(tmp_dir, "Elixir.Source.beam")

      File.write!(source_path, "defmodule Source do end")
      File.write!(beam_path, "beam")

      assert {:ok, beam_entry} = Entry.beam(beam_path, source_path)
      assert {:ok, source_entry} = Entry.source(source_path)

      manifest =
        [beam_entry]
        |> Manifest.new()
        |> Manifest.replace_output(source_path, [source_entry])

      assert [%Entry{kind: :source, input_path: ^source_path}] = Manifest.entries(manifest)
    end
  end

  defp beam_paths(tmp_dir, count) do
    root = Path.join(tmp_dir, "ebin")
    File.mkdir_p!(root)

    for index <- 1..count do
      Path.join(root, "dep#{index}.beam")
    end
  end
end
