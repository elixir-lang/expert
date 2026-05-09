defmodule Expert.Provider.Handlers.RenameTest do
  use ExUnit.Case, async: false

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers
  alias Forge.Document
  alias GenLSP.Requests.TextDocumentRename
  alias GenLSP.Structures

  setup_all do
    project = project(:navigations)

    start_supervised!({Forge.NodePortMapper, []})
    start_supervised!(Expert.Application.document_store_child_spec())
    start_supervised!({Expert.Project.Store, []})
    start_supervised!({DynamicSupervisor, Expert.Project.DynamicSupervisor.options()})
    start_supervised!({Expert.Project.Supervisor, project})

    Expert.Configuration.new() |> Expert.Configuration.set()

    EngineApi.register_listener(project, self(), [
      project_compiled(),
      project_index_ready()
    ])

    EngineApi.schedule_compile(project, true)
    assert_receive project_compiled(), 30_000
    assert_receive project_index_ready(), 30_000

    {:ok, project: project}
  end

  setup do
    :persistent_term.erase(Expert.Configuration)
    :ok
  end

  defp build_request(path, line, char, new_name) do
    uri = Document.Path.ensure_uri(path)

    with {:ok, _} <- Document.Store.open_temporary(uri) do
      req = %TextDocumentRename{
        id: Expert.Protocol.Id.next(),
        params: %Structures.RenameParams{
          text_document: %Structures.TextDocumentIdentifier{uri: uri},
          position: %Structures.Position{line: line, character: char},
          new_name: new_name
        }
      }

      Convert.to_native(req)
    end
  end

  defp handle(request, project) do
    Expert.Project.Store.add_projects([project])
    document = Document.Container.context_document(request, nil)
    context = Context.new(document.uri, document, project)
    Handlers.Rename.handle(request, context)
  end

  describe "rename" do
    test "renames a function and returns a WorkspaceEdit", %{project: project} do
      path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(path, 3, 6, "renamed_function")

      {:ok, workspace_edit} = handle(request, project)

      assert %Structures.WorkspaceEdit{changes: changes} = workspace_edit
      uri = Document.Path.ensure_uri(path)
      assert [_ | _] = edits = changes[uri]

      original = File.read!(path)
      result = Forge.Test.CodeMod.Case.apply_edits(original, edits, trim: false)
      assert result =~ "renamed_function"
      refute result =~ ~r/\bmy_function\b/
    end

    test "returns nil when cursor is not on a renameable symbol", %{project: project} do
      path = file_path(project, Path.join("lib", "uses.ex"))
      {:ok, request} = build_request(path, 0, 0, "anything")

      assert {:ok, nil} = handle(request, project)
    end
  end
end
