defmodule Expert.Document.Context do
  @moduledoc """
  Resolved document context.
  """

  alias Forge.Document
  alias Forge.Project

  @type kind :: :project | :bare

  @type t :: %__MODULE__{
          uri: Forge.uri() | nil,
          document: Document.t() | nil,
          project: Project.t() | nil,
          kind: kind()
        }

  defstruct [:uri, :document, :project, :kind]

  @spec project(Forge.uri(), Document.t() | nil, Project.t()) :: t()
  def project(uri, document, %Project{} = project) do
    %__MODULE__{uri: uri, document: document, project: project, kind: :project}
  end

  @spec bare(Forge.uri() | nil, Document.t() | nil) :: t()
  def bare(uri, document) do
    %__MODULE__{uri: uri, document: document, project: nil, kind: :bare}
  end
end
