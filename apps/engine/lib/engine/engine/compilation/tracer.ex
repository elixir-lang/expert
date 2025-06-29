defmodule Engine.Compilation.Tracer do
  alias Engine.Build
  alias Engine.Module.Loader

  import Forge.EngineApi.Messages

  def trace({:on_module, module_binary, _filename}, %Macro.Env{} = env) do
    message = extract_module_updated(env.module, module_binary, env.file)
    maybe_report_progress(env.file)
    Engine.broadcast(message)
    :ok
  end

  def trace(_event, _env) do
    :ok
  end

  def extract_module_updated(module, module_binary, filename) do
    unless Loader.ensure_loaded?(module) do
      erlang_filename =
        filename
        |> ensure_filename()
        |> String.to_charlist()

      :code.load_binary(module, erlang_filename, module_binary)
    end

    functions = module.__info__(:functions)
    macros = module.__info__(:macros)

    struct =
      if function_exported?(module, :__struct__, 0) do
        module.__struct__()
        |> Map.from_struct()
        |> Enum.map(fn {k, v} ->
          %{field: k, required?: !is_nil(v)}
        end)
      end

    module_updated(
      file: filename,
      functions: functions,
      macros: macros,
      name: module,
      struct: struct
    )
  end

  defp ensure_filename(:none) do
    unique = System.unique_integer([:positive, :monotonic])
    Path.join(System.tmp_dir(), "file-#{unique}.ex")
  end

  defp ensure_filename(filename) when is_binary(filename) do
    filename
  end

  defp maybe_report_progress(file) do
    if Path.extname(file) == ".ex" do
      file
      |> progress_message()
      |> Engine.broadcast()
    end
  end

  defp progress_message(file) do
    relative_path_elements =
      file
      |> Path.relative_to_cwd()
      |> Path.split()

    base_dir = List.first(relative_path_elements)
    file_name = List.last(relative_path_elements)

    message = "compiling: " <> Path.join([base_dir, "...", file_name])

    label = Build.State.building_label(Engine.get_project())
    project_progress(label: label, message: message)
  end
end
