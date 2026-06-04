# credo:disable-for-this-file Credo.Check.Readability.RedundantBlankLines
defmodule Engine.CodeMod.FormatTest do
  use Forge.Test.CodeMod.Case, enable_ast_conversion: false
  use Patch

  alias Engine.Build
  alias Engine.CodeMod.Format
  alias Forge.Document
  alias Forge.Project

  defmodule ProjectConfigFormatter do
    @behaviour Mix.Tasks.Format

    @impl Mix.Tasks.Format
    def features(_opts) do
      [extensions: [".ex"], sigils: []]
    end

    @impl Mix.Tasks.Format
    def format(contents, _opts) do
      :format_project = Mix.Project.config() |> Keyword.fetch!(:app)

      formatted = Code.format_string!(contents)
      IO.iodata_to_binary([formatted, ?\n])
    end
  end

  def apply_code_mod(text, _ast, opts) do
    project = Keyword.get(opts, :project)

    file_uri =
      opts
      |> Keyword.get(:file_path, file_path(project))
      |> maybe_uri()

    with {:ok, document_edits} <- Format.edits(document(file_uri, text)) do
      {:ok, document_edits.edits}
    end
  end

  def maybe_uri(path_or_uri) when is_binary(path_or_uri), do: Document.Path.to_uri(path_or_uri)
  def maybe_uri(not_binary), do: not_binary

  def document(file_uri, text) do
    Document.new(file_uri, text, 1)
  end

  def file_path(project) do
    Path.join([Project.root_path(project), "lib", "format.ex"])
  end

  def unformatted do
    ~q[
    defmodule Unformatted do
      def something(  a,     b  ) do
    end
    end
    ]t
  end

  def formatted do
    ~q[
    defmodule Unformatted do
      def something(a, b) do
      end
    end
    ]t
  end

  def with_patched_build(_) do
    patch(Build, :compile_document, fn _, _ -> :ok end)
    :ok
  end

  def write_formatter_plugin_project!(tmp_dir) do
    root = Path.join(tmp_dir, "format_project")
    lib_dir = Path.join(root, "lib")

    File.mkdir_p!(lib_dir)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule FormatProject.MixProject do
      use Mix.Project

      def project do
        [
          app: :format_project,
          version: "0.1.0",
          deps: []
        ]
      end
    end
    """)

    File.write!(Path.join(root, ".formatter.exs"), """
    [
      inputs: ["lib/**/*.{ex,exs}"],
      plugins: [#{inspect(ProjectConfigFormatter)}]
    ]
    """)

    File.write!(Path.join(lib_dir, "format.ex"), unformatted())

    root
    |> Document.Path.to_uri()
    |> Project.new()
  end

  setup do
    project = project()
    Engine.set_project(project)
    {:ok, project: project}
  end

  describe "format/2" do
    setup [:with_patched_build]

    test "it should be able to format a file in the project", %{project: project} do
      {:ok, result} = modify(unformatted(), project: project)

      assert result == formatted()
    end

    @tag :tmp_dir
    test "formatter plugins run with the formatted project's Mix config", %{tmp_dir: tmp_dir} do
      project = write_formatter_plugin_project!(tmp_dir)
      Engine.set_project(project)

      assert {:ok, result} =
               Mix.ProjectStack.on_clean_slate(fn ->
                 modify(unformatted(), project: project)
               end)

      assert result == formatted()
    end

    test "it will fail to format a file not in the project", %{project: project} do
      assert {:error, reason} = modify(unformatted(), file_path: "/tmp/foo.ex", project: project)
      assert reason =~ "Cannot format file /tmp/foo.ex"
      assert reason =~ "It is not in the project at"
    end

    test "it should provide an error for a syntax error", %{project: project} do
      assert {:error, %SyntaxError{}} = ~q[
      def foo(a, ) do
        true
      end
      ] |> modify(project: project)
    end

    test "it should provide an error for a missing token", %{project: project} do
      assert {:error, %TokenMissingError{}} = ~q[
      defmodule TokenMissing do
       :bad
      ] |> modify(project: project)
    end

    test "it correctly handles unicode", %{project: project} do
      assert {:ok, result} = ~q[
        {"🎸",    "o"}
      ] |> modify(project: project)

      assert ~q[
        {"🎸", "o"}
      ]t == result
    end

    test "it handles extra lines", %{project: project} do
      assert {:ok, result} = ~q[
        defmodule  Unformatted do
          def something(    a        ,   b) do



          end
      end
      ] |> modify(project: project)

      assert result == formatted()
    end

    test "it handles special characters", %{project: project} do
      assert {:ok, result} =
               ~q"""
               [
                 {"Karolína Plíšková","Kristýna Plíšková"}
               ]
               """
               |> modify(project: project)

      assert result ==
               """
               [
                 {"Karolína Plíšková", "Kristýna Plíšková"}
               ]
               """
               |> String.trim()
    end
  end
end
