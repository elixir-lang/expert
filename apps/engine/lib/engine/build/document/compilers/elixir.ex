defmodule Engine.Build.Document.Compilers.Elixir do
  @moduledoc """
  A compiler for elixir source files (.ex and .exs)
  """

  alias Elixir.Features
  alias Engine.Build
  alias Engine.Build.Document.Compilers
  alias Forge.Document

  @behaviour Build.Document.Compiler

  @impl true
  def recognizes?(%Document{} = doc) do
    doc.language_id in ["elixir", "elixir-script"]
  end

  @impl true
  def enabled?, do: true

  @impl true
  def compile(%Document{} = document) do
    case to_quoted(document) do
      {:ok, quoted} ->
        Compilers.Quoted.compile(document, quoted, "Elixir")

      {:error, {meta, message_info, token}} ->
        diagnostics = Build.Error.Parse.to_diagnostics(document, meta, message_info, token)
        {:error, diagnostics}
    end
  end

  defp to_quoted(document) do
    source_string = Document.to_string(document)
    parser_options = [file: document.path] ++ parser_options()
    Code.put_compiler_option(:ignore_module_conflict, true)
    Code.string_to_quoted(source_string, parser_options)
  end

  defp parser_options do
    [columns: true, token_metadata: true]
  end
end
