defmodule Expert.Provider.Handlers.RenameTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Provider.Handlers
  alias Forge.Document
  alias Forge.Document.Changes
  alias GenLSP.Requests.TextDocumentRename
  alias GenLSP.Structures

  setup_all do
    start_supervised(Expert.Application.document_store_child_spec())
    :ok
  end

  setup do
    :persistent_term.erase(Expert.Configuration)
    Expert.Configuration.new() |> Expert.Configuration.set()

    project = project()
    uri = subject_uri(project, "lib/my_app/users.ex")
    :ok = Document.Store.open(uri, "defmodule MyApp.Users do\nend\n", 1)
    {:ok, document} = Document.Store.fetch(uri)

    {:ok, project: project, document: document}
  end

  test "does not allow a file rename to overwrite its destination", %{
    project: project,
    document: document
  } do
    new_uri = subject_uri(project, "lib/my_app/accounts.ex")
    rename_file = Changes.RenameFile.new(document.uri, new_uri)
    changes = Changes.new(document, [], rename_file)
    patch(EngineApi, :rename, {:ok, [changes]})

    request = %TextDocumentRename{
      id: Expert.Protocol.Id.next(),
      params: %Structures.RenameParams{
        text_document: %Structures.TextDocumentIdentifier{uri: document.uri},
        position: %Structures.Position{line: 0, character: 10},
        new_name: "MyApp.Accounts"
      }
    }

    context = Context.new(document.uri, document, project)

    assert {:ok,
            %Structures.WorkspaceEdit{
              document_changes: [
                %Structures.TextDocumentEdit{},
                %Structures.RenameFile{
                  options: %Structures.RenameFileOptions{overwrite: false}
                }
              ]
            }} = Handlers.Rename.handle(request, context)
  end

  defp subject_uri(project, path) do
    project
    |> file_path(path)
    |> Document.Path.ensure_uri()
  end
end
