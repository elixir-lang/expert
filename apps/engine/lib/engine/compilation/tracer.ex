defmodule Engine.Compilation.Tracer do
  import Forge.EngineApi.Messages

  alias Engine.Build
  alias Engine.Compilation.TraceBuffer
  alias Engine.Module.Loader
  alias Engine.Progress

  def trace({:on_module, module_binary, _filename}, %Macro.Env{} = env) do
    maybe_record_module(env.file, module_binary, env.module)
    message = extract_module_updated(env.module, module_binary, env.file)
    maybe_report_progress(env.file)
    Engine.broadcast(message)
    :ok
  end

  def trace(_event, _env) do
    :ok
  end

  def extract_module_updated(module, module_binary, filename) do
    if !Loader.ensure_loaded?(module) do
      :code.load_binary(module, [], module_binary)
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

  defp maybe_report_progress(file) do
    with ".ex" <- Path.extname(file),
         token when not is_nil(token) <- Build.get_progress_token() do
      Progress.report(token, message: progress_message(file))
    end
  end

  defp maybe_record_module(file, module_binary, module)
       when is_binary(file) and is_binary(module_binary) and is_atom(module) do
    definitions =
      module
      |> Module.definitions_in()
      |> Enum.flat_map(fn definition ->
        case Module.get_definition(module, definition, skip_clauses: true) do
          {:v1, kind, metadata, []} -> [{definition, kind, metadata}]
          _ -> []
        end
      end)

    TraceBuffer.record_module(file, module_binary, module, definitions)
  end

  defp maybe_record_module(_file, _module_binary, _module), do: :ok

  defp progress_message(file) do
    relative_path_elements =
      file
      |> Path.relative_to_cwd()
      |> Path.split()

    base_dir = List.first(relative_path_elements)
    file_name = List.last(relative_path_elements)

    "compiling: " <> Path.join([base_dir, "...", file_name])
  end
end
