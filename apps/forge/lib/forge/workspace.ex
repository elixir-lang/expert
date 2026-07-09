defmodule Forge.Workspace do
  @moduledoc """
  The representation of the root directory where the server is running.
  """

  defstruct [:root_path, entropy: 1]

  @type t :: %__MODULE__{
          root_path: String.t() | nil,
          entropy: non_neg_integer()
        }

  @spec new(String.t()) :: t()
  def new(root_path) when is_binary(root_path) do
    %__MODULE__{
      root_path: root_path,
      entropy: :rand.uniform(65_536)
    }
  end

  def name(workspace) do
    Path.basename(workspace.root_path)
  end

  def set_workspace(workspace) do
    :persistent_term.put({__MODULE__, :workspace}, workspace)
  end

  def get_workspace do
    :persistent_term.get({__MODULE__, :workspace}, nil)
  end
end
