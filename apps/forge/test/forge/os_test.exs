defmodule Forge.OSTest do
  use ExUnit.Case
  use Patch

  describe "os_family/0" do
    test "returns :windows for win32" do
      patch(Forge.OS, :type, {:win32, :nt})

      assert Forge.OS.os_family() == :windows
    end

    test "returns :unix for non-win32 systems" do
      patch(Forge.OS, :type, {:unix, :darwin})

      assert Forge.OS.os_family() == :unix
    end
  end

  describe "os_type/0" do
    test "returns the first element of :os.type/0" do
      patch(Forge.OS, :type, {:unix, :linux})

      assert Forge.OS.os_type() == :unix
    end
  end
end
