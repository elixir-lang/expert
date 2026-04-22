defmodule Expert.Document.Context do
  @moduledoc """
  Resolved document context.
  """

  alias Forge.Document
  alias Forge.Project

  @type t :: %__MODULE__{
          uri: Forge.uri(),
          document: Document.t(),
          project: Project.t()
        }

  defstruct [:uri, :document, :project]

  @spec new(Forge.uri(), Document.t(), Project.t()) :: t()
  def new(uri, %Document{} = document, %Project{} = project) do
    %__MODULE__{uri: uri, document: document, project: project}
  end
end
