defmodule Forge.EPMDTest do
  use ExUnit.Case, async: false
  use Patch

  alias Forge.EPMD

  setup do
    original_port = :persistent_term.get(:expert_dist_port, :__missing__)

    on_exit(fn ->
      case original_port do
        :__missing__ -> :persistent_term.erase(:expert_dist_port)
        port -> :persistent_term.put(:expert_dist_port, port)
      end
    end)

    :ok
  end

  test "register_node stores dist port without calling erl_epmd" do
    patch(:erl_epmd, :register_node, fn _, _, _ ->
      flunk("should not call :erl_epmd.register_node/3")
    end)

    assert {:ok, -1} = EPMD.register_node(~c"expert-manager-test", 41_234, :inet)
    assert EPMD.dist_port() == 41_234
  end

  test "names returns address error without calling erl_epmd" do
    patch(:erl_epmd, :names, fn _ -> flunk("should not call :erl_epmd.names/1") end)

    assert EPMD.names(~c"localhost") == {:error, :address}
  end
end
