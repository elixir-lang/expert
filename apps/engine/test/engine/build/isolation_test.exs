defmodule Engine.Build.IsolationTest do
  use ExUnit.Case

  alias Engine.Build.Isolation

  defmodule OnlyMatchesOne do
    def call(1) do
      :ok
    end
  end

  test "returns {:ok, result} when the function succeeds" do
    assert {:ok, :ok} = Isolation.invoke(fn -> :ok end)
  end

  test "normalizes a raw function-clause crash into a proper exception" do
    assert {:error, {exception, stacktrace}} =
             Isolation.invoke(fn -> OnlyMatchesOne.call("not an integer") end)

    assert %FunctionClauseError{module: OnlyMatchesOne, function: :call, arity: 1} = exception
    assert [{OnlyMatchesOne, :call, _, _} | _] = stacktrace
  end

  test "keeps a raised exception struct" do
    assert {:error, {exception, stacktrace}} =
             Isolation.invoke(fn -> raise ArgumentError, "boom" end)

    assert %ArgumentError{message: "boom"} = exception
    assert is_list(stacktrace)
  end

  test "handles an exit" do
    assert {:error, :boom} =
             Isolation.invoke(fn -> exit(:boom) end)
  end

  test "handles a kill" do
    assert {:error, :killed} = Isolation.invoke(fn -> Process.exit(self(), :kill) end)
  end
end
