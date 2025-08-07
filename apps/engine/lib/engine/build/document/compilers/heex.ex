defmodule Engine.Build.Document.Compilers.HEEx do
  @moduledoc """
  A compiler for .heex files
  """
  alias Engine.Build.Document.Compiler
  alias Engine.Build.Document.Compilers
  alias Forge.Document
  alias Forge.Plugin.V1.Diagnostic.Result
  require Logger

  @behaviour Compiler

  def recognizes?(%Document{language_id: "phoenix-heex"}), do: true
  def recognizes?(%Document{language_id: "heex"}), do: true
  def recognizes?(_), do: false

  def enabled? do
    true
  end

  def compile(%Document{} = document) do
    with :ok <- eval_heex_quoted(document) do
      compile_eex_quoted(document)
    end
  end

  defp eval_heex_quoted(document) do
    with {:ok, quoted} <- heex_to_quoted(document) do
      Compilers.EEx.eval_quoted(document, quoted)
    end
  end

  defp compile_eex_quoted(document) do
    with {:error, errors} <- Compilers.EEx.compile(document) do
      {:error, reject_undefined_variables(errors)}
    end
  end

  defp reject_undefined_variables(errors) do
    # the undefined variable error is handled by the `eval_heex_quoted`
    Enum.reject(errors, fn error ->
      error.message =~ "undefined variable"
    end)
  end

  defp heex_to_quoted(%Document{} = document) do
    try do
      source = Document.to_string(document)

      opts = [
        source: source,
        file: document.path,
        caller: __ENV__,
        engine: Phoenix.LiveView.TagEngine,
        subengine: Phoenix.LiveView.Engine,
        tag_handler: Phoenix.LiveView.HTMLEngine
      ]

      quoted = EEx.compile_string(source, opts)

      {:ok, quoted}
    rescue
      error ->
        {:error, [error_to_result(document, error)]}
    end
  end

  defp error_to_result(%Document{} = document, %EEx.SyntaxError{} = error) do
    position = {error.line, error.column}

    Result.new(document.uri, position, error.message, :error, "EEx")
  end

  defp error_to_result(document, %error_struct{} = error)
       when error_struct in [
              SyntaxError,
              TokenMissingError,
              Phoenix.LiveView.Tokenizer.ParseError
            ] do
    position = {error.line, error.column}
    Result.new(document.uri, position, error.description, :error, "HEEx")
  end
end
