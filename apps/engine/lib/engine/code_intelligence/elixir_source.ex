defmodule Engine.CodeIntelligence.ElixirSource do
  @moduledoc """
  Autodetection of the Elixir standard library source path.
  """

  # A stable file that every standard Elixir install ships under its root.
  @sentinel "lib/elixir/lib/kernel.ex"

  @doc """
  Returns the root of the Elixir source tree for the current installation, or
  `nil` when it cannot be determined or does not ship sources.

  The returned path is such that `<root>/lib/elixir/lib/kernel.ex` exists.
  """
  @spec detect() :: String.t() | nil
  def detect do
    with dir when is_list(dir) <- :code.lib_dir(:elixir),
         root = dir |> List.to_string() |> Path.join("../..") |> Path.expand(),
         true <- File.exists?(Path.join(root, @sentinel)) do
      root
    else
      _ -> nil
    end
  end
end
