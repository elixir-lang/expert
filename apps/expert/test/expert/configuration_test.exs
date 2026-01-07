defmodule Expert.ConfigurationTest do
  use ExUnit.Case, async: true

  alias Expert.Configuration
  alias Forge.Document
  alias Forge.Project
  alias GenLSP.Structures.ClientCapabilities

  describe "new/4 with projectDir initialization option" do
    setup do
      tmp_dir = System.tmp_dir!()
      root_path = Path.join(tmp_dir, "test_root_#{System.unique_integer([:positive])}")
      sub_project_path = Path.join(root_path, "apps/my_app")

      File.mkdir_p!(sub_project_path)

      on_exit(fn ->
        File.rm_rf!(root_path)
      end)

      root_uri = Document.Path.to_uri(root_path)

      {:ok,
       root_uri: root_uri,
       root_path: root_path,
       sub_project_path: sub_project_path,
       client_capabilities: %ClientCapabilities{}}
    end

    test "uses root_uri when projectDir is not provided", ctx do
      config = Configuration.new(ctx.root_uri, ctx.client_capabilities, "test-client", %{})

      assert Project.root_path(config.project) == ctx.root_path
    end

    test "uses root_uri when init_options is empty map", ctx do
      config = Configuration.new(ctx.root_uri, ctx.client_capabilities, "test-client", %{})

      assert Project.root_path(config.project) == ctx.root_path
    end

    test "appends projectDir to root_uri when provided", ctx do
      init_options = %{"projectDir" => "apps/my_app"}

      config =
        Configuration.new(ctx.root_uri, ctx.client_capabilities, "test-client", init_options)

      assert Project.root_path(config.project) == ctx.sub_project_path
    end

    test "treats projectDir with leading slash as absolute path", ctx do
      init_options = %{"projectDir" => ctx.sub_project_path}

      config =
        Configuration.new(ctx.root_uri, ctx.client_capabilities, "test-client", init_options)

      assert Project.root_path(config.project) == ctx.sub_project_path
    end

    test "ignores empty projectDir string", ctx do
      init_options = %{"projectDir" => ""}

      config =
        Configuration.new(ctx.root_uri, ctx.client_capabilities, "test-client", init_options)

      assert Project.root_path(config.project) == ctx.root_path
    end

    test "ignores nil projectDir", ctx do
      init_options = %{"projectDir" => nil}

      config =
        Configuration.new(ctx.root_uri, ctx.client_capabilities, "test-client", init_options)

      assert Project.root_path(config.project) == ctx.root_path
    end
  end
end
