defmodule Engine.Rename do
  alias Engine.CodeMod
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Refactorex.Refactor

  require Logger

  @spec rename(Document.t(), Position.t(), String.t()) ::
          {:ok, Forge.Document.Changes.t()} | {:ok, nil} | {:error, term()}
  def rename(%Document{} = doc, %Position{} = position, new_name) when is_binary(new_name) do
    source = Document.to_string(doc)

    with {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, selection} <- selection_at(doc, source, position) do
      zipper = Sourceror.Zipper.zip(ast)

      if Refactor.rename_available?(zipper, selection) do
        %{refactored: new_source} = Refactor.rename(zipper, selection, new_name)
        {:ok, CodeMod.Format.source_to_changes(doc, new_source)}
      else
        {:ok, nil}
      end
    else
      {:error, reason} ->
        Logger.debug("Engine.Rename failed to parse or resolve selection: #{inspect(reason)}")
        {:ok, nil}
    end
  end

  defp selection_at(%Document{} = doc, source, %Position{line: line, character: character}) do
    case Code.Fragment.surround_context(source, {line, character}) do
      :none ->
        {:error, :no_context}

      %{begin: {begin_line, begin_col}, end: {end_line, end_col}} ->
        start_pos = Position.new(doc, begin_line, begin_col)
        end_pos = Position.new(doc, end_line, end_col)
        range = Range.new(start_pos, end_pos)

        fragment = Document.fragment(doc, range.start, range.end)

        Sourceror.parse_string(fragment, line: begin_line, column: begin_col)
    end
  end
end
