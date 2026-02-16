defmodule Forge.Code do
  @moduledoc false

  @doc """
  Parses an MFA string into a {module, function, arity} tuple.

  Returns `nil` if the string cannot be parsed or if the module doesn't exist.
  """
  @spec parse_mfa(String.t()) :: {module(), atom(), non_neg_integer()} | nil
  def parse_mfa(mfa_string) when is_binary(mfa_string) do
    case Regex.run(~r/^(.+)\.([^.\/]+)\/(\d+)$/, mfa_string) do
      [_, module_str, fun_str, arity_str] ->
        with {:ok, module} <- parse_module(module_str),
             {:ok, fun} <- parse_function(fun_str),
             {:ok, arity} <- parse_arity(arity_str) do
          {module, fun, arity}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_module(":" <> module_string) do
    {:ok, String.to_existing_atom(module_string)}
  rescue
    ArgumentError -> :error
  end

  defp parse_module(module_string) do
    {:ok, String.to_existing_atom("Elixir." <> module_string)}
  rescue
    ArgumentError -> :error
  end

  defp parse_function(fun_str) do
    {:ok, String.to_atom(fun_str)}
  end

  defp parse_arity(arity_str) do
    case Integer.parse(arity_str) do
      {arity, ""} when arity >= 0 -> {:ok, arity}
      _ -> :error
    end
  end
end
