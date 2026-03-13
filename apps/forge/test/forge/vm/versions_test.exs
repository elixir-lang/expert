defmodule Forge.VM.VersionTest do
  use ExUnit.Case
  use Patch

  import Forge.VM.Versions

  alias Forge.VM.Versions

  test "it gets the current version" do
    assert current().elixir == System.version()
  end

  test "it gets the current erlang version" do
    patch(Versions, :erlang_version, fn -> "25.3.2.1" end)
    assert current().erlang == "25.3.2.1"
  end

  test "it reads the versions in a directory" do
    patch(Versions, :read_file, fn "/foo/bar/baz/" <> file ->
      if String.ends_with?(file, ".erlang") do
        {:ok, "25.3.2.2"}
      else
        {:ok, "14.5.2"}
      end
    end)

    assert {:ok, tags} = read("/foo/bar/baz")

    assert tags.elixir == "14.5.2"
    assert tags.erlang == "25.3.2.2"
  end

  test "it writes the versions" do
    patch(Versions, :erlang_version, "25.3.2.1")
    patch(Versions, :write_file!, :ok)

    elixir_version = System.version()

    assert write("/foo/bar/baz")
    assert_called(Versions.write_file!("/foo/bar/baz/.erlang", "25.3.2.1"))
    assert_called(Versions.write_file!("/foo/bar/baz/.elixir", ^elixir_version))
  end

  def patch_system_versions(elixir, erlang) do
    patch(Versions, :elixir_version, elixir)
    patch(Versions, :erlang_version, erlang)
  end

  def patch_tagged_versions(elixir, erlang) do
    patch(Versions, :read_file, fn file ->
      if String.ends_with?(file, ".elixir") do
        {:ok, elixir}
      else
        {:ok, erlang}
      end
    end)
  end

  def with_exposed_normalize(_) do
    expose(Versions, normalize: 1)
    :ok
  end

  describe "normalize/1" do
    setup [:with_exposed_normalize]

    test "fixes a two-element version" do
      assert "25.0.0" == private(Versions.normalize("25.0"))
    end

    test "keeps three-element versions the same" do
      assert "25.3.2" == private(Versions.normalize("25.3.2"))
    end

    test "truncates versions with more than three elements" do
      assert "25.3.2" == private(Versions.normalize("25.3.2.2"))

      # I can't imagine they'd do this, but, you know, belt and suspenders
      assert "25.3.2" == private(Versions.normalize("25.3.2.1.2"))
      assert "25.3.2" == private(Versions.normalize("25.3.2.4.2.3"))
    end
  end

  test "an untagged directory is not compatible" do
    refute compatible?(System.tmp_dir!())
  end

  describe "compatible?/1" do
    test "lower major versions of erlang are compatible with later major versions" do
      patch_system_versions("1.15.8", "26.0")
      patch_tagged_versions("1.15.8", "25.0")

      assert compatible?("/foo/bar/baz")
    end

    test "higher major versions are not compatible with lower major versions" do
      patch_system_versions("1.15.8", "25.0")
      patch_tagged_versions("1.15.8", "26.0")

      refute compatible?("/foo/bar/baz")
    end

    test "the same versions are compatible with each other" do
      patch_system_versions("1.15.8", "25.3.3")
      patch_tagged_versions("1.15.8", "25.0")

      assert compatible?("/foo/bar/baz")
    end

    test "higher minor versions are compatible" do
      patch_system_versions("1.15.8", "25.3.0")
      patch_tagged_versions("1.15.8", "25.0")

      assert compatible?("/foo/bar/baz")
    end
  end
end
