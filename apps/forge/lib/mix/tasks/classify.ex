defmodule Mix.Tasks.Classify do
  use Mix.Task

  def run([base_directory, output_directory]) do
    classified_files = Forge.Namespace.FileSync.classify_files(base_directory, output_directory)

    Mix.Shell.IO.info("Changed files:")

    Enum.each(classified_files.changed, fn {base, output} ->
      Mix.Shell.IO.info("  Changed: #{base} -> #{output}")
    end)

    Mix.Shell.IO.info("New files:")

    Enum.each(classified_files.new, fn {base, output} ->
      Mix.Shell.IO.info("  New: #{base} -> #{output}")
    end)

    Mix.Shell.IO.info("Deleted files:")

    Enum.each(classified_files.deleted, fn output ->
      Mix.Shell.IO.info("  Deleted: #{output}")
    end)
  end
end
