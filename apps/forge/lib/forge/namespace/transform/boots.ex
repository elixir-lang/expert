defmodule Forge.Namespace.Transform.Boots do
  @moduledoc """
  A transformer that re-builds .boot files by converting a .script file
  """
  def apply_to_all(base_directory, opts \\ []) do
    base_directory
    |> find_boot_files()
    |> tap(fn boot_files ->
      Mix.Shell.IO.info("Rebuilding #{length(boot_files)} boot files")
    end)
    |> Enum.each(&run(&1, opts))
  end

  def run(file_path, _opts \\ []) do
    file_path
    |> Path.rootname()
    |> String.to_charlist()
    |> :systools.script2boot()
  end

  defp find_boot_files(base_directory) do
    [base_directory, "releases", "**", "*.script"]
    |> Path.join()
    |> Path.wildcard()
  end
end
