defmodule Engine.Build.Document.Compilers.Config do
  @moduledoc """
  A compiler for elixir configuration
  """
  alias Elixir.Features
  alias Engine.Build
  alias Engine.Build.Error.Location
  alias Forge.Document
  alias Forge.Plugin.V1.Diagnostic

  @elixir_source "Elixir"

  @behaviour Build.Document.Compiler
  require Logger

  @impl true
  def enabled?, do: true

  @impl true
  def recognizes?(%Document{} = document) do
    in_config_dir? =
      document.path
      |> Path.dirname()
      |> String.starts_with?(config_dir())

    in_config_dir? and Path.extname(document.path) == ".exs"
  end

  @impl true
  def compile(%Document{} = document) do
    if Features.with_diagnostics?() do
      compile_with_diagnostics(document)
    else
      raw_compile(document)
    end
  end

  defp config_dir do
    # This function is called inside a call to `in_project` so we can
    # call Mix.Project.config() directly
    Mix.Project.config()
    |> Keyword.get(:config_path)
    |> Path.expand()
    |> Path.dirname()
  end

  defp raw_compile(%Document{} = document) do
    contents = Document.to_string(document)

    try do
      Config.Reader.eval!(document.path, contents, env: :test)
      {:ok, []}
    rescue
      e ->
        {:error, [to_result(document, e, __STACKTRACE__)]}
    end
  end

  defp compile_with_diagnostics(%Document{} = document) do
    {result, diagnostics} =
      apply(Code, :with_diagnostics, [
        # credo:disable-for-previous-line
        fn ->
          raw_compile(document)
        end
      ])

    diagnostic_results = Enum.map(diagnostics, &to_result(document, &1))

    case result do
      {:error, errors} ->
        {:error, reject_logged_messages(errors ++ diagnostic_results)}

      _ ->
        {:ok, reject_logged_messages(diagnostic_results)}
    end
  end

  defp to_result(document, error, stack \\ [])

  defp to_result(%Document{} = document, %CompileError{} = error, _stack) do
    Diagnostic.Result.new(
      document.uri,
      error.line,
      Exception.message(error),
      :error,
      @elixir_source
    )
  end

  defp to_result(%Document{} = document, %error_type{} = error, _stack)
       when error_type in [SyntaxError, TokenMissingError] do
    Diagnostic.Result.new(
      document.uri,
      {error.line, error.column},
      Exception.message(error),
      :error,
      @elixir_source
    )
  end

  defp to_result(
         %Document{} = document,
         %{position: position, message: message, severity: severity},
         _stack
       ) do
    Diagnostic.Result.new(document.path, position, message, severity, @elixir_source)
  end

  defp to_result(%Document{} = document, %{__exception__: true} = exception, stack) do
    message = Exception.message(exception)
    position = Location.stack_to_position(stack)
    Diagnostic.Result.new(document.path, position, message, :error, @elixir_source)
  end

  defp reject_logged_messages(results) do
    Enum.reject(results, &(&1.message =~ "have been logged"))
  end
end
