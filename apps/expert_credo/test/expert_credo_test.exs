defmodule ExpertCredoTest do
  use ExUnit.Case

  import ExpertCredo

  alias Forge.Document
  alias Forge.Plugin.V1.Diagnostic.Result

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  def doc(contents) do
    Document.new("file:///file.ex", contents, 1)
  end

  test "reports errors on documents" do
    has_inspect =
      """
      defmodule Bad do
        def test do
          IO.inspect("hello")
        end
      end
      """
      |> doc()
      |> diagnose()

    assert {:ok, [%Result{} = result]} = has_inspect
    assert result.position == {3, 5}
    assert result.message == "There should be no calls to `IO.inspect/1`."
    assert String.ends_with?(result.uri, "/file.ex")
    assert result.severity == :warning
    assert result.source == "Credo"
  end
end
