defmodule Engine.Build.Document.Compilers.ElixirTest do
  alias Engine.Build.Document.Compilers
  alias Forge.Document

  use ExUnit.Case
  import Compilers.Elixir

  def document_with_extension(extension) do
    Document.new("file:///foo#{extension}", "", 0)
  end

  describe "recognizes?/1" do
    test "it recognizes .ex documents" do
      assert recognizes?(document_with_extension(".ex"))
    end

    test "it recognizes .exs documents" do
      assert recognizes?(document_with_extension(".exs"))
    end

    test "it doesn't recognize .html documents" do
      refute recognizes?(document_with_extension(".html"))
    end

    test "it doesn't recognize .js documents" do
      refute recognizes?(document_with_extension(".js"))
    end

    test "it doesn't recognize .eex documents" do
      refute recognizes?(document_with_extension(".eex"))
      refute recognizes?(document_with_extension(".html.eex"))
    end

    test "it doesn't recognize .heex documents" do
      refute recognizes?(document_with_extension(".heex"))
      refute recognizes?(document_with_extension(".html.heex"))
    end
  end
end
