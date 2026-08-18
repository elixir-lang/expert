defmodule Forge.DiagnosticTest do
  use ExUnit.Case, async: true

  alias Forge.Diagnostic

  test "normalizes the URI and iodata message" do
    diagnostic = Diagnostic.new("/tmp/example.ex", 3, ["bad", ?!], :error, "Elixir", :details)

    assert %Diagnostic{
             uri: "file:///tmp/example.ex",
             position: 3,
             message: "bad!",
             severity: :error,
             source: "Elixir",
             details: :details
           } = diagnostic
  end
end
