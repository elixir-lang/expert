defmodule Engine.Compilation.TraceProgress do
  @moduledoc false

  alias Engine.Build
  alias Engine.Progress

  def report(file) when is_binary(file) do
    with ".ex" <- Path.extname(file),
         token when token != nil <- Build.get_progress_token() do
      Progress.report(token, message: progress_message(file))
    end
  end

  def report(_file), do: :ok

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
