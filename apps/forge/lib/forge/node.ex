defmodule Forge.Node do
  @moduledoc false

  @problematic_chars [?., ?@, ?:, ?-, ?\s]

  @doc """
  Sanitizes a string to be safe for use in Erlang node names.

  Replaces problematic characters (`.`, `@`, `:`, `-`, space) with underscores.
  These characters either break the `name@host` format or cause issues in atoms.

  ## Examples

      iex> Forge.Node.sanitize("my-project")
      "my_project"

      iex> Forge.Node.sanitize("expert-lsp.org")
      "expert_lsp_org"

      iex> Forge.Node.sanitize("MyProject")
      "MyProject"

      iex> Forge.Node.sanitize("プロジェクト")
      "プロジェクト"

  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(name) when is_binary(name) do
    name
    |> String.to_charlist()
    |> Enum.map(fn char ->
      if char in @problematic_chars, do: ?_, else: char
    end)
    |> List.to_string()
  end
end
