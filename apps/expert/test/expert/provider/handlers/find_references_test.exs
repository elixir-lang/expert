defmodule Expert.Provider.Handlers.FindReferencesTest do
  alias Expert.EngineApi
  alias Expert.Provider.Handlers
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Location
  alias Expert.Protocol.Convert
  alias GenLSP.Requests.TextDocumentReferences
  alias GenLSP.Structures

  import Forge.Test.Fixtures

  use ExUnit.Case, async: false
  use Patch

  setup_all do
    start_supervised(Expert.Application.document_store_child_spec())
    :ok
  end

  setup do
    project = project(:navigations)
    path = file_path(project, Path.join("lib", "my_definition.ex"))
    uri = Document.Path.ensure_uri(path)
    {:ok, project: project, uri: uri}
  end

  def build_request(path, line, char) do
    uri = Document.Path.ensure_uri(path)

    with {:ok, _} <- Document.Store.open_temporary(uri) do
      req = %TextDocumentReferences{
        id: Expert.Protocol.Id.next(),
        params: %Structures.ReferenceParams{
          context: %Structures.ReferenceContext{
            include_declaration: true
          },
          text_document: %Structures.TextDocumentIdentifier{uri: uri},
          position: %Structures.Position{line: line, character: char}
        }
      }

      Convert.to_native(req)
    end
  end

  def handle(request, project) do
    config = Expert.Configuration.new(project: project)
    Handlers.FindReferences.handle(request, config)
  end

  describe "find references" do
    test "returns locations that the entity returns", %{project: project, uri: uri} do
      patch(EngineApi, :references, fn ^project, %Analysis{document: document}, _position, _ ->
        locations = [
          Location.new(
            Document.Range.new(
              Document.Position.new(document, 1, 5),
              Document.Position.new(document, 1, 10)
            ),
            Document.Path.to_uri("/path/to/file.ex")
          )
        ]

        locations
      end)

      {:ok, request} = build_request(uri, 5, 6)

      assert {:ok, [%Location{} = location]} = handle(request, project)
      assert location.uri =~ "file.ex"
    end

    test "returns nothing if the entity can't resolve it", %{project: project, uri: uri} do
      patch(EngineApi, :references, nil)

      {:ok, request} = build_request(uri, 1, 5)

      assert {:ok, nil} == handle(request, project)
    end
  end
end
