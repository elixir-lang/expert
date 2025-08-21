defmodule Forge.Namespace.Transform.Beams do
  @moduledoc """
  A transformer that finds and replaces any instance of a module in a .beam file
  """

  def apply_to_all(base_directory, opts) do
    Mix.Shell.IO.info("Rewriting .beam files")
    consolidated_beams = find_consolidated_beams(base_directory)
    app_beams = find_app_beams(base_directory, opts[:apps])

    Mix.Shell.IO.info(" Found #{length(consolidated_beams)} protocols")
    Mix.Shell.IO.info(" Found #{length(app_beams)} app beam files")

    all_beams = Enum.concat(consolidated_beams, app_beams)
    total_files = length(all_beams)

    me = self()

    all_beams
    |> Task.async_stream(
      fn beam ->
        apply_and_update_progress(beam, me, opts)
      end,
      timeout: 10_000
    )
    |> Stream.run()

    block_until_done(0, total_files)
  end

  defp apply_and_update_progress(beam_file, caller, opts) do
    run(beam_file, opts)
    send(caller, :progress)
  end

  def run(path, opts) do
    do_apps = opts[:do_apps]
    erlang_path = String.to_charlist(path)

    Process.put(:do_apps, do_apps)

    with {:ok, forms} <- abstract_code(erlang_path),
         rewritten_forms = Forge.Namespace.Abstract.run(forms, opts),
         true <- changed?(forms, rewritten_forms),
         {:ok, module_name, binary} <- Forge.Namespace.Code.compile(rewritten_forms) do
      write_module_beam(path, module_name, binary)
    end
  end

  defp changed?(same, same), do: false
  defp changed?(_, _), do: true

  defp block_until_done(same, same) do
    Mix.Shell.IO.info("\n done")
  end

  defp block_until_done(current, max) do
    receive do
      :progress -> :ok
    end

    current = current + 1
    IO.write("\r")
    percent_complete = format_percent(current, max)

    IO.write(" Applying namespace: #{percent_complete} complete")
    block_until_done(current, max)
  end

  defp find_consolidated_beams(base_directory) do
    [base_directory, "**", "consolidated", "*.beam"]
    |> Path.join()
    |> Path.wildcard()
  end

  defp find_app_beams(base_directory, apps) do
    namespaced_apps = Enum.join(apps, ",")
    apps_glob = "{#{namespaced_apps}}"

    [base_directory, "lib", apps_glob, "ebin/**", "*.beam"]
    |> Path.join()
    |> Path.wildcard()
  end

  defp write_module_beam(old_path, module_name, binary) do
    ebin_path = Path.dirname(old_path)
    new_beam_path = Path.join(ebin_path, "#{module_name}.beam")

    with :ok <- File.write(new_beam_path, binary, [:binary, :raw]) do
      unless old_path == new_beam_path do
        # avoids deleting modules that did not get a new name
        # e.g. Elixir.Mix.Task.. etc
        File.rm(old_path)
      end
    end
  end

  defp abstract_code(path) do
    with {:ok, {_orig_module, code_parts}} <- :beam_lib.chunks(path, [:abstract_code]),
         {:ok, {:raw_abstract_v1, forms}} <- Keyword.fetch(code_parts, :abstract_code) do
      {:ok, forms}
    else
      _ ->
        {:error, :not_found}
    end
  end

  defp format_percent(current, max) do
    int_val =
      (current / max * 100)
      |> round()
      |> Integer.to_string()

    String.pad_leading("#{int_val}%", 4)
  end
end
