defmodule Expert.CodeIntelligence.Hex.ContextTest do
  use ExUnit.Case, async: true

  import Forge.Test.CursorSupport

  alias Expert.CodeIntelligence.Hex.Context
  alias Forge.Ast

  defp detect(text) do
    {position, document} = pop_cursor(text, document: "mix.exs")

    analysis =
      document
      |> Ast.analyze()
      |> Ast.reanalyze_to(position)

    Context.detect(analysis, position)
  end

  test "returns :error when there is no deps function" do
    text = ~S"""
    defmodule MyApp do
      def hello, do: :wo|rld
    end
    """

    assert :error = detect(text)
  end

  test "does NOT detect version slot when cursor is immediately after the closing quote" do
    # Cursor at `"~> 1.7"|` sits past the closing delimiter — the user is
    # moving on to the next token, not still editing the version.
    text = ~S"""
    defmodule MyApp.MixProject do
      use Mix.Project

      defp deps do
        [
          {:phoenix, "~> 1.7"|}
        ]
      end
    end
    """

    assert :error = detect(text)
  end

  test "detects version slot when cursor is on the closing quote of a version" do
    # Just before `"~> 1.7"`'s closing quote — user is still editing the
    # version string and could backspace into it.
    text = ~S"""
    defmodule MyApp.MixProject do
      use Mix.Project

      defp deps do
        [
          {:phoenix, "~> 1.7|"}
        ]
      end
    end
    """

    assert {:ok, ctx} = detect(text)
    assert ctx.slot == :version
    assert ctx.package == "phoenix"
  end

  test "detects cursor inside the version string of a 2-tuple" do
    text = ~S"""
    defmodule MyApp.MixProject do
      use Mix.Project

      defp deps do
        [
          {:phoenix, "~> 1.|"}
        ]
      end
    end
    """

    assert {:ok, ctx} = detect(text)
    assert ctx.slot == :version
    assert ctx.package == "phoenix"
    assert ctx.prefix == "~> 1."
  end

  test "detects bare atom prefix at position 1 of a tuple in defp deps" do
    text = ~S"""
    defmodule MyApp.MixProject do
      use Mix.Project

      defp deps do
        [
          {:phoe|, "~> 1.7"}
        ]
      end
    end
    """

    assert {:ok, ctx} = detect(text)
    assert ctx.slot == :name
    assert ctx.prefix == "phoe"
  end

  test "detects cursor in a bare keyword key after a version" do
    text = ~S"""
    defmodule MyApp.MixProject do
      use Mix.Project

      defp deps do
        [
          {:phoenix, "~> 1.7", on|}
        ]
      end
    end
    """

    assert {:ok, ctx} = detect(text)
    assert ctx.slot == :opts
    assert ctx.package == "phoenix"
    assert ctx.prefix == "on"
  end

  test "works with explicit empty parens on the deps definition" do
    text = ~S"""
    defmodule MyApp.MixProject do
      use Mix.Project

      defp deps() do
        [
          {:phoe|, "~> 1.7"}
        ]
      end
    end
    """

    assert {:ok, ctx} = detect(text)
    assert ctx.slot == :name
    assert ctx.prefix == "phoe"
  end

  test "works with public def deps do/end" do
    text = ~S"""
    defmodule MyApp.MixProject do
      use Mix.Project

      def deps do
        [
          {:phoe|, "~> 1.7"}
        ]
      end
    end
    """

    assert {:ok, ctx} = detect(text)
    assert ctx.slot == :name
    assert ctx.prefix == "phoe"
  end

  test "detects :version slot in a mid-edit tuple with an unclosed version string" do
    # The user is mid-typing a version requirement. Sourceror's error
    # recovery collapses the second arg into an `{:~>, _, _}` operator
    # expression (absorbing chars until the next real `"`), so the
    # argument is not a clean binary literal. We still know the package
    # atom from the first arg and must classify the cursor as :version.
    text = ~S"""
    defmodule Grove.MixProject do
      use Mix.Project

      defp deps do
        [
          {:phoenix, "~> 1.|
          {:oban_pro, "~> 1.5", repo: "oban"},
          {:spake2, "~> 0.1"}
        ]
      end
    end
    """

    assert {:ok, ctx} = detect(text)
    assert ctx.slot == :version
    assert ctx.package == "phoenix"
    assert ctx.prefix == "~> 1."
  end

  test "detects :name slot in a realistic mid-edit mix.exs with a large deps list" do
    # Reproduces the grove scenario: the user is mid-typing a new dep on
    # the first line of an already-populated deps list. Sourceror's
    # parse-error recovery replaces the broken tuple with a `:__cursor__`
    # node, and whatever `collect_dep_tuples` is doing today discards the
    # surrounding well-formed tuples as well. We must still detect a :name
    # slot with prefix "phonn".
    text = ~S"""
    defmodule Grove.MixProject do
      use Mix.Project

      def project do
        [app: :grove, version: "0.1.0", deps: deps()]
      end

      defp deps do
        [
          {:phonn|
          {:oban_pro, "~> 1.5", repo: "oban"},
          {:spake2, "~> 0.1"},
          {:telemetry, "~> 1.0"},
          {:gen_stage, "~> 1.2"},
          {:elixir_make, "~> 0.8", runtime: false},
          {:bandit, "~> 1.0"},
          {:plug, "~> 1.16"},
          {:mint_web_socket, "~> 1.0"},
          {:ex_doc, "~> 0.35", only: :docs, runtime: false},
          {:exsync, "~> 0.4", only: :dev},
          {:mimic, "~> 2.3", only: :test},
          {:mox, "~> 1.0", only: :test},
          {:req, "~> 0.5", only: [:dev, :test]},
          {:tidewave, "~> 0.5", only: :dev}
        ]
      end
    end
    """

    assert {:ok, ctx} = detect(text)
    assert ctx.slot == :name
    assert ctx.prefix == "phonn"
  end

  test "detects :name slot on a standalone unclosed tuple like {:phoen|" do
    # The user is starting a brand-new dep with no closing brace and nothing
    # else in the list — the tightest recovery case. We should still be able
    # to produce a :name slot with prefix "phoen" so package completion
    # results can fire.
    text = ~S"""
    defmodule MyApp.MixProject do
      use Mix.Project

      defp deps do
        [
          {:phoen|
        ]
      end
    end
    """

    assert {:ok, ctx} = detect(text)
    assert ctx.slot == :name
    assert ctx.prefix == "phoen"
  end

  test "still detects slot when an earlier tuple in the list is mid-edit" do
    # The unclosed `{:phonin` on line 6 makes the mix.exs a parse-error
    # state. Sourceror recovers the rest of the list via `:comma` nodes; we
    # should still detect the cursor in a *later*, well-formed tuple.
    text = ~S"""
    defmodule Grove.MixProject do
      use Mix.Project

      defp deps do
        [
          {:phonin
          {:ban|dit, "~> 1.0"},
          {:req, "~> 0.5"}
        ]
      end
    end
    """

    assert {:ok, ctx} = detect(text)
    assert ctx.slot == :name
    assert ctx.prefix == "ban"
  end

  test "returns :error when cursor is in project/0 but not inside deps/0" do
    text = ~S"""
    defmodule MyApp.MixProject do
      use Mix.Project

      def project do
        [ap|p: :my_app, deps: deps()]
      end

      defp deps do
        [{:phoenix, "~> 1.7"}]
      end
    end
    """

    assert :error = detect(text)
  end
end
