defmodule Expert.Provider.Handlers.CodeLens do
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Expert.Provider.Handlers
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Project
  alias GenLSP.Requests
  alias GenLSP.Structures

  import Document.Line
  require Logger

  def handle(
        %Requests.TextDocumentCodeLens{params: %Structures.CodeLensParams{} = params},
        %Configuration{} = config
      ) do
    document = Document.Container.context_document(params, nil)

    lenses =
      case reindex_lens(config.project, document) do
        nil -> []
        lens -> List.wrap(lens)
      end

    {:ok, lenses}
  end

  defp reindex_lens(%Project{} = project, %Document{} = document) do
    if show_reindex_lens?(project, document) do
      range = def_project_range(document)
      command = Handlers.Commands.reindex_command(project)

      %Structures.CodeLens{command: command, range: range}
    end
  end

  @project_regex ~r/def\s+project\s/
  defp def_project_range(%Document{} = document) do
    # returns the line in mix.exs where `def project` occurs
    Enum.reduce_while(document.lines, nil, fn
      line(text: line_text, line_number: line_number), _ ->
        if String.match?(line_text, @project_regex) do
          start_pos = Position.new(document, line_number, 1)
          end_pos = Position.new(document, line_number, String.length(line_text))
          range = Range.new(start_pos, end_pos)
          {:halt, range}
        else
          {:cont, nil}
        end
    end)
  end

  defp show_reindex_lens?(%Project{} = project, %Document{} = document) do
    document_path = normalize_path(document.path)
    mix_exs_path = normalize_path(Project.mix_exs_path(project))

    document_path == mix_exs_path and
      not EngineApi.index_running?(project)
  end

  defp normalize_path(path) do
    path
    |> Path.expand()
    |> Forge.Path.normalize()
  end
end
