defmodule Expert.CodeIntelligence.DepsTest do
  use ExUnit.Case, async: true

  alias Expert.CodeIntelligence.Deps
  alias Forge.Ast

  defp deps_list(text) do
    doc = Forge.Document.new("file:///mix.exs", text, 0)
    analysis = Ast.analyze(doc)

    case Deps.list(analysis.ast) do
      {:ok, list} -> list
      :error -> []
    end
  end

  describe "repo_of/1" do
    test "returns 'hexpm' when no :repo or :organization is set" do
      [tuple] =
        deps_list("""
        defmodule M do
          defp deps do
            [{:phoenix, "~> 1.7"}]
          end
        end
        """)

      assert Deps.repo_of(tuple) == "hexpm"
    end

    test "returns 'hexpm:<org>' when organization is set" do
      [tuple] =
        deps_list("""
        defmodule M do
          defp deps do
            [{:my_pkg, "~> 1.0", organization: "myorg"}]
          end
        end
        """)

      assert Deps.repo_of(tuple) == "hexpm:myorg"
    end

    test "returns the literal repo name when :repo is set" do
      [tuple] =
        deps_list("""
        defmodule M do
          defp deps do
            [{:my_pkg, "~> 1.0", repo: "internal"}]
          end
        end
        """)

      assert Deps.repo_of(tuple) == "internal"
    end

    test ":repo wins over :organization when both are set" do
      [tuple] =
        deps_list("""
        defmodule M do
          defp deps do
            [{:my_pkg, "~> 1.0", organization: "myorg", repo: "internal"}]
          end
        end
        """)

      assert Deps.repo_of(tuple) == "internal"
    end

    test "returns 'hexpm' for a 2-tuple with no opts" do
      [tuple] =
        deps_list("""
        defmodule M do
          defp deps do
            [{:phoenix, "~> 1.7"}]
          end
        end
        """)

      assert Deps.repo_of(tuple) == "hexpm"
    end
  end

  describe "list/1 on incomplete (mid-edit) source" do
    test "collects surviving dep tuples when one entry is unclosed" do
      # The user is mid-edit: the `{:phonin` tuple is missing its version and
      # closing brace. Sourceror recovers the rest of the list via internal
      # `:comma` / error markers — we should still find every tuple that has
      # a recognisable atom package name.
      tuples =
        deps_list("""
        defmodule M do
          defp deps do
            [
              {:phonin
              {:circuits_uart, "~> 1.5"},
              {:bandit, "~> 1.0"},
              {:req, "~> 0.5"}
            ]
          end
        end
        """)

      package_names = Enum.map(tuples, &package_name/1)
      assert :phonin in package_names
      assert :circuits_uart in package_names
      assert :bandit in package_names
      assert :req in package_names
    end

    test "returns :error when there is no deps function at all" do
      assert [] == deps_list("defmodule M do\n  def hello, do: :world\nend\n")
    end

    test "handles a dep with a keyword opts tail in a parse-recovered file" do
      tuples =
        deps_list("""
        defmodule M do
          defp deps do
            [
              {:phoenix, "~> 1.7", only: [:dev, :test]},
              {:broken
              {:ecto, "~> 3.0"}
            ]
          end
        end
        """)

      package_names = Enum.map(tuples, &package_name/1)
      assert :phoenix in package_names
      assert :ecto in package_names
      assert :broken in package_names
    end
  end

  describe "cursor_in_deps_body?/1" do
    defp ast_at_cursor(text) do
      {position, document} = Forge.Test.CursorSupport.pop_cursor(text, document: "mix.exs")

      document
      |> Ast.analyze()
      |> Ast.reanalyze_to(position)
      |> Map.fetch!(:ast)
    end

    test "returns true when Forge's fragment parse places :__cursor__ inside deps/0" do
      # Mid-typing a brand new dep inside the deps list — Forge's
      # fragment-aware reanalysis inserts :__cursor__ where the user is
      # typing, which `cursor_in_deps_body?/1` finds via a prewalk of
      # the deps function body.
      ast =
        ast_at_cursor(~S"""
        defmodule M.MixProject do
          defp deps do
            [
              {:phoen|
              {:req, "~> 0.5"}
            ]
          end
        end
        """)

      assert Deps.cursor_in_deps_body?(ast)
    end

    test "returns false when the cursor is in a non-deps function body" do
      ast =
        ast_at_cursor(~S"""
        defmodule M.MixProject do
          def project do
            [app: :my_app, deps: dep|s()]
          end

          defp deps do
            [{:req, "~> 0.5"}]
          end
        end
        """)

      refute Deps.cursor_in_deps_body?(ast)
    end

    test "returns false when there is no deps/0 function" do
      ast =
        ast_at_cursor(~S"""
        defmodule M do
          def hello, do: :wo|rld
        end
        """)

      refute Deps.cursor_in_deps_body?(ast)
    end
  end

  # Helper: pull the package name atom out of a dep tuple AST node of either shape.
  defp package_name({:__block__, _, [{{:__block__, _, [name]}, _}]}) when is_atom(name),
    do: name

  defp package_name({:{}, _, [{:__block__, _, [name]} | _]}) when is_atom(name), do: name
  defp package_name(_), do: :unknown
end
