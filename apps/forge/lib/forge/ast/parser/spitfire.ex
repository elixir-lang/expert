defmodule Forge.Ast.Parser.Spitfire do
  @moduledoc false

  defp opts do
    [
      literal_encoder: &{:ok, {:__block__, &2, [&1]}},
      token_metadata: true,
      columns: true,
      unescape: false
    ]
  end

  def string_to_quoted(string) when is_binary(string) do
    case Spitfire.parse_with_comments(string, opts()) do
      {:ok, quoted, comments} ->
        {:ok, quoted, comments}

      {:error, quoted, comments, errors} ->
        first = hd(errors)
        {:error, quoted, first, comments}

      {:error, :no_fuel_remaining} ->
        {:error, {[line: 1, column: 1], "parser exhausted fuel"}, []}
    end
  rescue
    e ->
      {:error, :crashed, e, __STACKTRACE__}
  end

  def container_cursor_to_quoted(fragment) when is_binary(fragment) do
    case Spitfire.container_cursor_to_quoted(fragment, opts()) do
      {:ok, quoted} ->
        {:ok, quoted}

      {:error, quoted, errors} ->
        first = hd(errors)
        {:error, quoted, first}

      {:error, :no_fuel_remaining} ->
        {:error, {[line: 1, column: 1], "parser exhausted fuel"}}
    end
  rescue
    e ->
      {:error, :crashed, e, __STACKTRACE__}
  end
end
