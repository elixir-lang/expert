defmodule Forge.Workspace do
  @moduledoc """
  The representation of the root directory where the server is running.
  """

  alias Forge.Document

  defstruct [:root_path, workspace_folders: []]

  @type t :: %__MODULE__{
          root_path: String.t() | nil,
          workspace_folders: [String.t()]
        }

  @spec new(String.t() | nil, [String.t()]) :: t()
  def new(root_path, workspace_folders \\ []) do
    %__MODULE__{root_path: root_path, workspace_folders: workspace_folders}
  end

  @spec add_folders(t(), [String.t()]) :: t()
  def add_folders(%__MODULE__{} = workspace, folder_paths) when is_list(folder_paths) do
    existing = MapSet.new(workspace.workspace_folders)

    new_folders =
      folder_paths
      |> Enum.reject(&MapSet.member?(existing, &1))

    %__MODULE__{workspace | workspace_folders: workspace.workspace_folders ++ new_folders}
  end

  @spec remove_folders(t(), [String.t()]) :: t()
  def remove_folders(%__MODULE__{} = workspace, folder_paths) when is_list(folder_paths) do
    to_remove = MapSet.new(folder_paths)

    %__MODULE__{
      workspace
      | workspace_folders:
          Enum.reject(workspace.workspace_folders, &MapSet.member?(to_remove, &1))
    }
  end

  @spec folder_path_from_uri(String.t()) :: String.t()
  def folder_path_from_uri(uri) when is_binary(uri) do
    Document.Path.from_uri(uri)
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
