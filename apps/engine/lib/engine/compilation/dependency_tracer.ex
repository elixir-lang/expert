defmodule Engine.Compilation.DependencyTracer do
  @moduledoc false

  import Forge.EngineApi.Messages

  alias Engine.Compilation.TraceBuffer
  alias Engine.Compilation.TraceProgress
  alias Engine.Search.Indexer.Beams

  def trace({:on_module, module_binary, _filename}, %Macro.Env{} = env) do
    file = canonical_path(env.file)

    TraceProgress.report(file)

    maybe_broadcast_exports(module_binary, file)
    maybe_buffer_definitions(module_binary, file, env.module)

    :ok
  end

  def trace(_event, _env), do: :ok

  defp maybe_broadcast_exports(module_binary, file) do
    case Beams.extract_exports_from_binary(module_binary) do
      {:ok, exports} -> Engine.broadcast(module_updated_message(exports, file))
      :error -> :ok
    end
  end

  defp module_updated_message(exports, file) do
    module_updated(
      file: file,
      functions: exports.functions,
      macros: exports.macros,
      name: exports.module,
      struct: exports.struct
    )
  end

  defp maybe_buffer_definitions(module_binary, file, module)
       when is_binary(file) and is_atom(module) do
    case Beams.extract_definitions_from_binary(module_binary, source_path: file) do
      {:ok, definitions} ->
        TraceBuffer.add_definitions(file, module, definitions)
        maybe_buffer_beam_path(file, module)

      :error ->
        :ok
    end
  end

  defp maybe_buffer_definitions(_module_binary, _file, _module), do: :ok

  defp maybe_buffer_beam_path(file, module) do
    case beam_path(module) do
      beam_path when is_binary(beam_path) -> TraceBuffer.add_beam_path(file, beam_path)
      _ -> :ok
    end
  end

  defp beam_path(module) when is_atom(module) do
    if Engine.Mix.loaded?() do
      Path.join(Mix.Project.compile_path(), "#{Atom.to_string(module)}.beam")
    end
  end

  defp canonical_path(path) when is_binary(path), do: path |> Path.expand() |> Forge.Path.native()
  defp canonical_path(path), do: path
end
