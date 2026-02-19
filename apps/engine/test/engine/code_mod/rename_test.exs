defmodule Engine.CodeMod.RenameTest do
  alias Engine.CodeMod.Rename
  alias Engine.Search
  alias Engine.Search.Store.Backends
  alias Forge.Document

  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures
  import Forge.Test.EventualAssertions

  setup do
    project = project()

    Backends.Ets.destroy_all(project)
    Engine.set_project(project)

    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    start_supervised!(Engine.Dispatch)
    start_supervised!(Backends.Ets)

    start_supervised!(
      {Search.Store, [project, fn _ -> {:ok, []} end, fn _, _ -> {:ok, [], []} end, Backends.Ets]}
    )

    Search.Store.enable()
    assert_eventually(Search.Store.loaded?(), 1500)

    on_exit(fn ->
      Backends.Ets.destroy_all(project)
    end)

    {:ok, project: project}
  end

  describe "prepare/2" do
    test "returns module name" do
      {:ok, result, _} =
        ~q[
        defmodule |Users do
        end
      ]
        |> prepare()

      assert result == "Users"
    end

    test "returns full module name" do
      {:ok, result, _} =
        ~q[
        defmodule MyApp.|Users do
        end
      ]
        |> prepare()

      assert result == "MyApp.Users"
    end

    test "returns full module name when cursor is in the middle" do
      {:ok, result, _} =
        ~q[
        defmodule My|App.Users do
        end
      ]
        |> prepare()

      assert result == "MyApp.Users"
    end

    test "returns nil for module reference" do
      assert {:ok, nil} =
               ~q[
        defmodule MyApp.Users do
        end

        defmodule MyApp.Accounts do
          alias |MyApp.Users
        end
      ]
               |> prepare()
    end

    # Returns {:ok, nil} instead of an error because gen_lsp 0.11.x has a
    # serialization bug where ErrorResponse crashes in Schematic.oneof.
    # See commit message for details.
    test "returns nil for unsupported entity" do
      assert {:ok, nil} =
               ~q[
          x = 1
          |x
      ]
               |> prepare()
    end

    @tag :skip
    # TODO: restore once gen_lsp fixes ErrorResponse serialization in oneof,
    # so we can return a user-friendly message via the LSP error response.
    test "returns error with friendly message for unsupported entity" do
      assert {:error, "Renaming :variable is not supported for now"} =
               ~q[
          x = 1
          |x
      ]
               |> prepare()
    end
  end

  describe "rename/4 basic" do
    test "renames at definition" do
      {:ok, result} =
        ~q[
        defmodule |Users do
        end
      ]
        |> rename("Accounts")

      assert result =~ ~S[defmodule Accounts do]
    end

    test "fails at alias reference" do
      assert {:error, {:unsupported_location, :module}} ==
               ~q[
        defmodule MyApp.Accounts do
          alias |MyApp.Users
        end
      ]
               |> rename("Members")
    end

    test "fails at module call reference" do
      assert {:error, {:unsupported_location, :module}} ==
               ~q[
        defmodule MyApp.Accounts do
          alias MyApp.Users
          Use|rs.list()
        end
      ]
               |> rename("Members")
    end

    test "renames multi-part module" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Auth.|Session do
        end
      ]
        |> rename("MyApp.Auth.Token")

      assert result =~ ~S[defmodule MyApp.Auth.Token do]
    end

    test "renames middle segment" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Auth.|Session do
        end
      ]
        |> rename("MyApp.Identity.Session")

      assert result =~ ~S[defmodule MyApp.Identity.Session do]
    end

    test "simplifies module name" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Auth.|Session do
        end
      ]
        |> rename("MyApp.Session")

      assert result =~ ~S[defmodule MyApp.Session do]
    end

    test "renames nested module definition" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Users do
          defmodule |Query do
          end
        end

        defmodule MyApp.UsersTest do
          alias MyApp.Users.Query
        end
      ]
        |> rename("Filter")

      assert result == ~q[
        defmodule MyApp.Users do
          defmodule Filter do
          end
        end

        defmodule MyApp.UsersTest do
          alias MyApp.Users.Filter
        end
      ]
    end

    test "renames multi-alias syntax" do
      {:ok, result} =
        ~q[
        defmodule MyApp.|Accounts do
        end

        defmodule MyApp.Web do
          alias MyApp.{
            Users, Accounts,
            Auth.Session
          }
        end
      ]
        |> rename("MyApp.Members")

      assert result =~ ~S[  Users, Members,]
    end
  end

  describe "rename/4 with references" do
    test "does not rename similar module names" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Users do
        end

        defmodule MyApp.UsersTest do
        end
        ]
        |> rename("MyApp.Accounts")

      assert result =~ ~S[defmodule MyApp.UsersTest do]
    end

    test "renames local references when local name changes" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Users do
        end

        defmodule MyApp.UsersTest do
          alias MyApp.Users
          Users.list()
        end
        ]
        |> rename("MyApp.Accounts")

      assert result =~ ~S[alias MyApp.Accounts]
      assert result =~ ~S[ Accounts.list()]
    end

    test "keeps local reference when local name unchanged" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Users do
        end

        defmodule MyApp.Admin do
          alias MyApp.Users

          Users.list() # no change
        end
      ]
        |> rename("MyApp.Core.Users")

      assert result =~ ~S[defmodule MyApp.Core.Users do]
      assert result =~ ~S[alias MyApp.Core.Users]
      assert result =~ ~S[ Users.list() # no change]
    end

    test "keeps local reference when only prefix changes" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Core.Utils do
        end

        defmodule MyApp.Web do
          alias MyApp.Core.Utils

          Utils.format() # no change
        end
      ]
        |> rename("MyApp.Shared.Utils")

      assert result =~ ~S[defmodule MyApp.Shared.Utils do]
      assert result =~ ~S[alias MyApp.Shared.Utils]
      assert result =~ ~S[ Utils.format() # no change]
    end
  end

  describe "rename/4 descendants" do
    test "renames descendants" do
      {:ok, result} =
        ~q[
        defmodule MyApp.|Users do
        end

        defmodule MyApp.Users.Query do
        end
      ]
        |> rename("MyApp.Accounts")

      assert result =~ ~S[defmodule MyApp.Accounts.Query]
      assert result =~ ~S[defmodule MyApp.Accounts do]
    end

    test "renames descendants when expanding name" do
      {:ok, result} =
        ~q[
        defmodule MyApp.|Users do
          alias MyApp.Users.Query
        end

        defmodule MyApp.Users.Query do
        end
      ]
        |> rename("MyApp.Core.Users")

      assert result =~ ~S[defmodule MyApp.Core.Users]
      assert result =~ ~S[alias MyApp.Core.Users.Query]
      assert result =~ ~S[defmodule MyApp.Core.Users.Query do]
    end

    test "renames descendants with multi-part expansion" do
      {:ok, result} =
        ~q[
        defmodule MyApp.|Auth do
        end

        defmodule MyApp.Auth.Session do
        end

        defmodule MyApp.AuthTest do
          alias MyApp.Auth
          alias MyApp.Auth.Session
        end
      ]
        |> rename("MyApp.Auth.OAuth")

      assert result =~ ~S[defmodule MyApp.Auth.OAuth do]
      assert result =~ ~S[alias MyApp.Auth.OAuth]
      assert result =~ ~S[alias MyApp.Auth.OAuth.Session]
    end

    test "handles repeated module name in path" do
      {:ok, result} =
        ~q[
          defmodule MyApp.Core.MyApp.|Core do
          end

          defmodule MyApp.Core.MyApp.Core.Utils do
          end

          defmodule MyApp.Web do
            alias MyApp.Core.MyApp.Core.Utils
          end
        ]
        |> rename("MyApp.Core.MyApp.Shared")

      assert result =~ ~S[defmodule MyApp.Core.MyApp.Shared do]
      assert result =~ ~S[defmodule MyApp.Core.MyApp.Shared.Utils do]
      assert result =~ ~S[alias MyApp.Core.MyApp.Shared.Utils]
    end

    test "skips same-named nested modules" do
      {:ok, result} =
        ~q[
        defmodule MyApp.|Users do
          defmodule Users do # skip this
          end
        end

        defmodule MyApp.Admin do
          alias MyApp.Users.Users
        end
      ]
        |> rename("MyApp.Accounts")

      assert result =~ ~S[defmodule MyApp.Accounts do]
      assert result =~ ~S[defmodule Users do # skip this]
      assert result =~ ~S[alias MyApp.Accounts.Users]
    end

    test "renames when removing middle segment" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Core.Users do
        end

        defmodule MyApp.Core.Users.Query do
          alias MyApp.Core.Users.Query
        end
      ]
        |> rename("MyApp.Users")

      assert result =~ ~S[defmodule MyApp.Users.Query do]
      assert result =~ ~S[alias MyApp.Users.Query]
    end

    test "does not rename modules containing old suffix as substring" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Ast do
        end

        defmodule MyApp.Parser do
          alias MyApp.Ast.Detection

          Detection.Bitstring.detected?() # Bitstring contains the old suffix: `st`
        end
      ]
        |> rename("MyApp.AST")

      refute result =~ ~S[Detection.BitSTring.detected?()]
    end
  end

  describe "rename/4 struct" do
    test "renames struct references" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.User do
          defstruct name: nil, email: nil
        end

        defmodule MyApp.Accounts do
          def new do
            %MyApp.User{}
          end
        end
      ]
        |> rename("MyApp.Account")

      assert result =~ ~S[defmodule MyApp.Account do]
      assert result =~ ~S[%MyApp.Account{}]
    end

    test "renames struct in pattern matching" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.User do
          defstruct name: nil, email: nil
        end

        defmodule MyApp.Accounts do
          def get_name(%MyApp.User{name: name}), do: name
        end
      ]
        |> rename("MyApp.Account")

      assert result =~ ~S[def get_name(%MyApp.Account{name: name})]
    end

    test "renames struct update syntax" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.User do
          defstruct name: nil, email: nil
        end

        defmodule MyApp.Accounts do
          def update(user, name) do
            %MyApp.User{user | name: name}
          end
        end
      ]
        |> rename("MyApp.Account")

      assert result =~ ~S[%MyApp.Account{user | name: name}]
    end
  end

  describe "rename/4 edge cases" do
    test "does not rename module with similar prefix" do
      # MyApp.User should not affect MyApp.UserProfile
      {:ok, result} =
        ~q[
        defmodule |MyApp.User do
        end

        defmodule MyApp.UserProfile do
        end

        defmodule MyApp.Consumer do
          alias MyApp.User
          alias MyApp.UserProfile
        end
      ]
        |> rename("MyApp.Account")

      assert result =~ ~S[defmodule MyApp.Account do]
      # UserProfile should NOT be renamed
      assert result =~ ~S[defmodule MyApp.UserProfile do]
      assert result =~ ~S[alias MyApp.UserProfile]
    end

    test "does not rename module that contains old name as substring" do
      # Renaming MyApp.API should not affect MyApp.SomeAPIService
      {:ok, result} =
        ~q[
        defmodule |MyApp.API do
        end

        defmodule MyApp.SomeAPIService do
        end
      ]
        |> rename("MyApp.Gateway")

      assert result =~ ~S[defmodule MyApp.Gateway do]
      # SomeAPIService should NOT be renamed to SomeGatewayService
      assert result =~ ~S[defmodule MyApp.SomeAPIService do]
    end

    test "correctly renames when old and new names share common prefix" do
      # MyApp.User -> MyApp.UserAccount (extending the name)
      {:ok, result} =
        ~q[
        defmodule |MyApp.User do
        end

        defmodule MyApp.Consumer do
          alias MyApp.User
        end
      ]
        |> rename("MyApp.UserAccount")

      assert result =~ ~S[defmodule MyApp.UserAccount do]
      assert result =~ ~S[alias MyApp.UserAccount]
    end

    test "correctly renames when new name is shorter" do
      # MyApp.UserAccount -> MyApp.User (shortening the name)
      {:ok, result} =
        ~q[
        defmodule |MyApp.UserAccount do
        end

        defmodule MyApp.Consumer do
          alias MyApp.UserAccount
        end
      ]
        |> rename("MyApp.User")

      assert result =~ ~S[defmodule MyApp.User do]
      assert result =~ ~S[alias MyApp.User]
    end

    test "handles renaming module with single segment name" do
      {:ok, result} =
        ~q[
        defmodule |Users do
        end

        defmodule Consumer do
          alias Users
        end
      ]
        |> rename("Accounts")

      assert result =~ ~S[defmodule Accounts do]
      assert result =~ ~S[alias Accounts]
    end

    test "handles renaming to completely different module path" do
      # MyApp.Users -> OtherApp.Accounts (different prefix entirely)
      {:ok, result} =
        ~q[
        defmodule |MyApp.Users do
        end

        defmodule MyApp.Consumer do
          alias MyApp.Users
        end
      ]
        |> rename("OtherApp.Accounts")

      assert result =~ ~S[defmodule OtherApp.Accounts do]
      assert result =~ ~S[alias OtherApp.Accounts]
    end

    test "renames deeply nested module correctly" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Core.Domain.Users.Query do
        end

        defmodule MyApp.Web do
          alias MyApp.Core.Domain.Users.Query
        end
      ]
        |> rename("MyApp.Core.Domain.Users.Filter")

      assert result =~ ~S[defmodule MyApp.Core.Domain.Users.Filter do]
      assert result =~ ~S[alias MyApp.Core.Domain.Users.Filter]
    end

    test "does not corrupt nearby code when renaming" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Users do
          @moduledoc "Users module"

          def list, do: :ok
        end

        defmodule MyApp.UsersTest do
          use ExUnit.Case
        end
      ]
        |> rename("MyApp.Accounts")

      # Verify the module is renamed
      assert result =~ ~S[defmodule MyApp.Accounts do]
      # Verify other code is preserved
      assert result =~ ~S[@moduledoc "Users module"]
      assert result =~ ~S[def list, do: :ok]
      # UsersTest should NOT be renamed (different module)
      assert result =~ ~S[defmodule MyApp.UsersTest do]
    end
  end

  describe "rename/4 file renaming" do
    setup do
      patch(Engine.CodeMod.Rename.File, :function_exists?, false)
      :ok
    end

    test "does not rename file with parent module", %{project: project} do
      {:ok, {_applied, nil}} =
        ~q[
        defmodule MyApp.Server do
          defmodule |State do
          end
        end
        ]
        |> rename_with_file("Config", "lib/my_app/server.ex", project)
    end

    test "does not rename file with sibling modules", %{project: project} do
      assert {:ok, {_applied, nil}} =
               ~q[
        defmodule |MyApp.Users do
        end

        defmodule MyApp.Accounts do
        end
        ]
               |> rename_with_file("Members", "lib/my_app/users.ex", project)
    end

    test "does not rename file for non-conventional path", %{project: project} do
      assert {:ok, {_applied, nil}} =
               ~q[
        defmodule |MyApp.MixProject do
        end
        ]
               |> rename_with_file("MyApp.Renamed", "mix.exs", project)
    end

    test "renames lib file", %{project: project} do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule |MyApp.Users do
        end
      ]
        |> rename_with_file("MyApp.Accounts", "lib/my_app/users.ex", project)

      assert rename_file.new_uri == subject_uri(project, "lib/my_app/accounts.ex")
    end

    test "does not rename file when only case changes", %{project: project} do
      assert {:ok, {_applied, nil}} =
               ~q[
        defmodule |MyApp.Users do
        end
        ]
               |> rename_with_file("MyApp.USERS", "lib/my_app/users.ex", project)
    end

    test "renames umbrella app file", %{project: project} do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule |MyApp.Users do
        end
      ]
        |> rename_with_file("MyApp.Accounts", "apps/my_app/lib/my_app/users.ex", project)

      assert rename_file.new_uri == subject_uri(project, "apps/my_app/lib/my_app/accounts.ex")
    end

    test "renames umbrella app nested file", %{project: project} do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule |Engine.CodeMod do
        end
      ]
        |> rename_with_file(
          "Engine.Refactor",
          "apps/engine/lib/engine/code_mod.ex",
          project
        )

      assert rename_file.new_uri ==
               subject_uri(project, "apps/engine/lib/engine/refactor.ex")
    end

    test "renames test file", %{project: project} do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule |MyApp.UsersTest do
        end
      ]
        |> rename_with_file("MyApp.AccountsTest", "test/my_app/users_test.exs", project)

      assert rename_file.new_uri == subject_uri(project, "test/my_app/accounts_test.exs")
    end

    test "preserves components folder for phoenix component", %{project: project} do
      patch(Engine.CodeMod.Rename.File, :phoenix_component_module?, fn MyAppWeb.IconComponent ->
        true
      end)

      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule MyAppWeb.|IconComponent do
        end
      ]
        |> rename_with_file(
          "MyAppWeb.BadgeComponent",
          "lib/my_app_web/components/icon_component.ex",
          project
        )

      assert rename_file.new_uri ==
               subject_uri(project, "lib/my_app_web/components/badge_component.ex")
    end

    test "preserves components folder for nested component", %{project: project} do
      patch(
        Engine.CodeMod.Rename.File,
        :phoenix_component_module?,
        fn MyAppWeb.Admin.IconComponent -> true end
      )

      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule MyAppWeb.Admin.|IconComponent do
        end
      ]
        |> rename_with_file(
          "MyAppWeb.Admin.BadgeComponent",
          "lib/my_app_web/components/admin/icon_component.ex",
          project
        )

      assert rename_file.new_uri ==
               subject_uri(project, "lib/my_app_web/components/admin/badge_component.ex")
    end

    test "preserves components folder when Components in module name", %{project: project} do
      patch(
        Engine.CodeMod.Rename.File,
        :phoenix_component_module?,
        fn MyAppWeb.Components.Icons ->
          true
        end
      )

      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule MyAppWeb.Components.|Icons do
        end
      ]
        |> rename_with_file(
          "MyAppWeb.Components.Badges",
          "lib/my_app_web/components/icons.ex",
          project
        )

      assert rename_file.new_uri ==
               subject_uri(project, "lib/my_app_web/components/badges.ex")
    end

    test "preserves controllers folder", %{project: project} do
      patch(
        Engine.CodeMod.Rename.File,
        :phoenix_controller_module?,
        fn MyAppWeb.UserController -> true end
      )

      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule MyAppWeb.|UserController do
        end
      ]
        |> rename_with_file(
          "MyAppWeb.AccountController",
          "lib/my_app_web/controllers/user_controller.ex",
          project
        )

      assert rename_file.new_uri ==
               subject_uri(project, "lib/my_app_web/controllers/account_controller.ex")
    end

    test "preserves controllers folder for JSON module", %{project: project} do
      patch(
        Engine.CodeMod.Rename.File,
        :phoenix_controller_module?,
        fn MyAppWeb.UserController.JSON -> true end
      )

      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule MyAppWeb.UserController.|JSON do
        end
      ]
        |> rename_with_file(
          "MyAppWeb.UserController.API",
          "lib/my_app_web/controllers/user_controller/json.ex",
          project
        )

      assert rename_file.new_uri ==
               subject_uri(project, "lib/my_app_web/controllers/user_controller/api.ex")
    end

    test "preserves live folder", %{project: project} do
      patch(Engine.CodeMod.Rename.File, :phoenix_liveview_module?, fn MyAppWeb.UserLive ->
        true
      end)

      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule MyAppWeb.|UserLive do
        end
      ]
        |> rename_with_file("MyAppWeb.AccountLive", "lib/my_app_web/live/user_live.ex", project)

      assert rename_file.new_uri == subject_uri(project, "lib/my_app_web/live/account_live.ex")
    end
  end

  # Helpers

  defp prepare(code) do
    with {position, code} <- pop_cursor(code),
         {:ok, _document, analysis} <- index(code) do
      Rename.prepare(analysis, position)
    end
  end

  defp rename(code, new_name) do
    with {position, code} <- pop_cursor(code),
         {:ok, document, analysis} <- index(code),
         {:ok, results} <- Rename.rename(analysis, position, new_name, nil) do
      case results do
        [%Document.Changes{edits: edits, document: doc}] ->
          {:ok, edited_doc} =
            Document.apply_content_changes(doc, doc.version + 1, edits)

          {:ok, Document.to_string(edited_doc)}

        [] ->
          {:ok, Document.to_string(document)}
      end
    end
  end

  defp rename_with_file(code, new_name, path, project) do
    uri = subject_uri(project, path)

    with {position, text} <- pop_cursor(code),
         {:ok, document} <- open_document(uri, text),
         {:ok, entries} <- Engine.Search.Indexer.Source.index_document(document),
         :ok <- Search.Store.replace(entries),
         {:ok, _document, analysis} <- Document.Store.fetch(uri, :analysis),
         {:ok, document_changes} <- Rename.rename(analysis, position, new_name, nil) do
      changes = document_changes |> Enum.map(& &1.edits) |> List.flatten()
      applied = apply_edits(document, changes)
      rename_file = document_changes |> Enum.map(& &1.rename_file) |> List.first()

      {:ok, {applied, rename_file}}
    end
  end

  defp index(code) do
    project = project()
    uri = module_uri(project)

    with :ok <- Document.Store.open(uri, code, 1),
         {:ok, document, analysis} <- Document.Store.fetch(uri, :analysis),
         {:ok, entries} <- Engine.Search.Indexer.Quoted.index(analysis) do
      Search.Store.replace(entries)
      {:ok, document, analysis}
    end
  end

  defp module_uri(project) do
    project
    |> file_path(Path.join("lib", "my_module.ex"))
    |> Document.Path.ensure_uri()
  end

  defp subject_uri(project, path) do
    project
    |> file_path(path)
    |> Document.Path.ensure_uri()
  end

  defp open_document(uri, content) do
    with :ok <- Document.Store.open(uri, content, 0) do
      Document.Store.fetch(uri)
    end
  end

  defp apply_edits(document, text_edits) do
    {:ok, edited_document} = Document.apply_content_changes(document, 1, text_edits)
    Document.to_string(edited_document)
  end
end
