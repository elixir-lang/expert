defmodule Forge.Workspace do
  @moduledoc """
  The representation of the root directory where the server is running.
  """

  defstruct [:root_path]

  @type t :: %__MODULE__{
          root_path: String.t() | nil
        }

  def new(root_path) do
    %__MODULE__{root_path: root_path}
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
