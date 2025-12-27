defmodule Forge.Namespace.Transform.Beams do
  @moduledoc """
  A transformer that finds and replaces any instance of a module in a .beam file
  """

  alias Forge.Namespace.Abstract
  alias Forge.Namespace.Code

  def apply_to_all(base_directory) do
    Mix.Shell.IO.info("Rewriting .beam files")
    consolidated_beams = find_consolidated_beams(base_directory)
    app_beams = find_app_beams(base_directory)

    Mix.Shell.IO.info(" Found #{length(consolidated_beams)} protocols")
    Mix.Shell.IO.info(" Found #{length(app_beams)} app beam files")

    all_beams = Enum.concat(consolidated_beams, app_beams)
    total_files = length(all_beams)

    me = self()

    spawn(fn ->
      all_beams
      |> Task.async_stream(
        &apply_and_update_progress(&1, me),
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()
    end)

    block_until_done(0, total_files)
  end

  def apply(path) do
    erlang_path = String.to_charlist(path)

    with {:ok, forms} <- abstract_code(erlang_path),
         rewritten_forms = Abstract.rewrite(forms),
         true <- changed?(forms, rewritten_forms),
         {:ok, module_name, binary} <- Code.compile(rewritten_forms) do
      write_module_beam(path, module_name, binary)
    end
  end

  defp changed?(same, same), do: false
  defp changed?(_, _), do: true

  defp block_until_done(same, same, last_write_time \\ nil)

  defp block_until_done(same, same, _last_write_time), do: Mix.Shell.IO.info("\n done")

  defp block_until_done(current, max, last_write_time) do
    receive do
      :progress -> :ok
    end

    current = current + 1

    last_write_time = log_completion_debounced(current, max, last_write_time)

    block_until_done(current, max, last_write_time)
  end

  defp log_completion_debounced(current, max, last_write_time) when is_integer(last_write_time) do
    now = :erlang.monotonic_time(:millisecond)

    if now - last_write_time >= 66 do
      IO.write("\r")
      IO.write("Applying namespace: #{format_percent(current, max)} complete")

      now
    else
      last_write_time
    end
  end

  defp log_completion_debounced(current, max, _last_write_time) do
    IO.write("\r")
    IO.write("Applying namespace: #{format_percent(current, max)} complete")

    :erlang.monotonic_time(:millisecond)
  end

  defp apply_and_update_progress(beam_file, caller) do
    apply(beam_file)
    send(caller, :progress)
  end

  defp find_consolidated_beams(base_directory) do
    [base_directory, "releases", "**", "consolidated", "*.beam"]
    |> Path.join()
    |> Path.wildcard()
  end

  defp find_app_beams(base_directory) do
    namespaced_apps = Enum.join(Mix.Tasks.Namespace.app_names(), ",")
    apps_glob = "{#{namespaced_apps}}*"

    [base_directory, "lib", apps_glob, "**", "*.beam"]
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
      |> floor()
      |> Integer.to_string()

    String.pad_leading("#{int_val}%", 4)
  end
end
