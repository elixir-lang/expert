defmodule Expert.Project.DiagnosticsTest do
  alias Expert.EngineApi
  alias Expert.Test.DispatchFake
  alias Forge.Document
  alias Forge.Plugin.V1.Diagnostic
  alias GenLSP.Notifications.TextDocumentPublishDiagnostics
  alias GenLSP.Structures
  alias GenLSP.Structures.PublishDiagnosticsParams

  use ExUnit.Case
  use Patch
  use DispatchFake

  import Forge.EngineApi.Messages
  import Forge.Test.Fixtures

  setup do
    project = project()
    DispatchFake.start()

    start_supervised!(Forge.Document.Store)
    start_supervised!({Expert.Project.Diagnostics, project})

    {:ok, project: project}
  end

  def diagnostic(file_path, opts \\ []) do
    defaults = [
      uri: Document.Path.ensure_uri(file_path),
      severity: :error,
      message: "stuff broke",
      position: 1,
      compiler_name: "Elixir"
    ]

    values = Keyword.merge(defaults, opts)
    struct(Diagnostic.Result, values)
  end

  def with_patched_tranport(_) do
    test = self()

    patch(GenLSP, :notify_server, fn _, message ->
      send(test, {:transport, message})
    end)

    patch(GenLSP, :notify, fn _, message ->
      send(test, {:transport, message})
    end)

    patch(GenLSP, :request, fn _, message ->
      send(test, {:transport, message})
    end)

    :ok
  end

  defp open_file(project, contents) do
    uri = file_uri(project, "lib/project.ex")
    :ok = Document.Store.open(uri, contents, 0)
    {:ok, document} = Document.Store.fetch(uri)
    document
  end

  describe "clearing diagnostics on compile" do
    setup [:with_patched_tranport]

    test "it clears a file's diagnostics if it's not dirty", %{
      project: project
    } do
      document = open_file(project, "defmodule Foo")

      file_diagnostics_message =
        file_diagnostics(diagnostics: [diagnostic(document.uri)], uri: document.uri)

      EngineApi.broadcast(project, file_diagnostics_message)

      expected_severity = GenLSP.Enumerations.DiagnosticSeverity.error()

      assert_receive {:transport,
                      %TextDocumentPublishDiagnostics{
                        params: %PublishDiagnosticsParams{
                          diagnostics: [
                            %Structures.Diagnostic{
                              message: "stuff broke",
                              severity: ^expected_severity,
                              source: nil
                            }
                          ]
                        }
                      }}

      Document.Store.get_and_update(document.uri, &{:ok, Document.mark_clean(&1)})

      EngineApi.broadcast(project, project_compile_requested())
      EngineApi.broadcast(project, project_diagnostics(diagnostics: []))

      assert_receive {:transport,
                      %TextDocumentPublishDiagnostics{
                        params: %PublishDiagnosticsParams{diagnostics: []}
                      }}
    end

    test "it clears a file's diagnostics if it has been closed", %{
      project: project
    } do
      document = open_file(project, "defmodule Foo")

      file_diagnostics_message =
        file_diagnostics(diagnostics: [diagnostic(document.uri)], uri: document.uri)

      EngineApi.broadcast(project, file_diagnostics_message)
      assert_receive {:transport, %TextDocumentPublishDiagnostics{}}, 500

      Document.Store.close(document.uri)

      EngineApi.broadcast(project, project_compile_requested())
      EngineApi.broadcast(project, project_diagnostics(diagnostics: []))

      assert_receive {:transport,
                      %TextDocumentPublishDiagnostics{
                        params: %PublishDiagnosticsParams{diagnostics: []}
                      }}
    end

    test "it adds a diagnostic to the last line if they're out of bounds", %{project: project} do
      document = open_file(project, "defmodule Dummy do\n  .\nend\n")
      # only 3 lines in the file, but elixir compiler gives us a line number of 4
      diagnostic =
        diagnostic(document.uri,
          position: {4, 1},
          message: "missing terminator: end (for \"do\" starting at line 1)"
        )

      file_diagnostics_message = file_diagnostics(diagnostics: [diagnostic], uri: document.uri)

      EngineApi.broadcast(project, file_diagnostics_message)

      assert_receive {:transport,
                      %TextDocumentPublishDiagnostics{
                        params: %PublishDiagnosticsParams{diagnostics: [diagnostic]}
                      }},
                     500

      assert %Structures.Diagnostic{} = diagnostic

      assert diagnostic.range == %GenLSP.Structures.Range{
               end: %Structures.Position{character: 0, line: 3},
               start: %Structures.Position{character: 0, line: 3}
             }
    end
  end
end
