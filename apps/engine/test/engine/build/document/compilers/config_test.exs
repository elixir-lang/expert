defmodule Engine.Build.Document.Compilers.ConfigTest do
  use ExUnit.Case

  import Engine.Build.Document.Compilers.Config
  import Forge.Test.CodeSigil

  alias Forge.Document

  def document_with_path(left, right) do
    left
    |> Path.join(right)
    |> document_with_path()
  end

  def document_with_path(path) when is_list(path) do
    path
    |> Path.join()
    |> document_with_path()
  end

  def document_with_path(path) do
    Document.new(path, "", 1)
  end

  def document(contents) do
    config_dir()
    |> Path.join("config.exs")
    |> Document.new(contents, 0)
  end

  def config_dir do
    Mix.Project.config()
    |> Keyword.get(:config_path)
    |> Path.expand()
    |> Path.dirname()
  end

  describe "recognizes/1" do
    test "files in the config directory are detected" do
      assert recognizes?(document_with_path(config_dir(), "test.exs"))
      assert recognizes?(document_with_path(config_dir(), "foo.exs"))
      assert recognizes?(document_with_path([config_dir(), "other", "foo.exs"]))
    end

    test "files in the config directory with relative paths are detected" do
      assert recognizes?(document_with_path("./config/test.exs"))
    end

    test "files outside the config directory are not detected" do
      refute recognizes?(document_with_path(__ENV__.file))
    end

    test "only .exs files are detected" do
      refute recognizes?(document_with_path(config_dir(), "foo.ex"))
      refute recognizes?(document_with_path(config_dir(), "foo.yaml"))
      refute recognizes?(document_with_path(config_dir(), "foo.eex"))
      refute recognizes?(document_with_path(config_dir(), "foo.heex"))
    end
  end

  describe "compile/1" do
    test "it produces diagnostics for syntax errors" do
      assert {:error, [result]} =
               ",="
               |> document()
               |> compile()

      assert result.message =~ "syntax error before"
      assert result.position == {1, 1}
      assert result.severity == :error
      assert result.source == "Elixir"
    end

    test "it produces diagnostics for compile errors" do
      assert {:error, [result]} =
               ~q[
                 import Config
                 configure :my_app, key: 3
               ]
               |> document()
               |> compile()

      assert result.message =~ "undefined function"
      assert result.position == 2
      assert result.severity == :error
      assert result.source == "Elixir"
    end

    test "it produces diagnostics for Token missing errors" do
      assert {:error, [result]} =
               "fn foo -> e"
               |> document()
               |> compile()

      assert result.message =~ "missing terminator"
      assert result.position in [{1, 12}, {1, 1}]
      assert result.severity == :error
      assert result.source == "Elixir"
    end

    test "it produces diagnostics even in the `config_env` block" do
      assert {:error, [result]} =
               ~q[
                 import Config

                 if config_env() == :product do
                   f
                 end
               ]
               |> document()
               |> compile()

      if Features.with_diagnostics?() do
        assert result.message =~ ~s[undefined variable "f"]
      else
        assert result.message =~ ~s[undefined function f/0]
      end

      assert result.position == 4
      assert result.severity == :error
      assert result.source == "Elixir"
    end

    test "it produces diagnostics for arbitrary exceptions" do
      assert {:error, [result]} =
               ~q[
                 import Config

                 System.fetch_env!("_EXPERT_NON_EXISTING_ENV_VAR_")
               ]
               |> document()
               |> compile()

      assert result.message =~ "could not fetch environment variable"
      assert result.severity == :error
      assert result.source == "Elixir"

      if Features.with_diagnostics?() do
        assert result.position == 3
      end
    end

    test "it produces no diagnostics on success" do
      assert {:ok, []} =
               ~q[
                 import Config
                 config :my_app, key: 3, other_key: 6
               ]
               |> document()
               |> compile()
    end
  end
end
