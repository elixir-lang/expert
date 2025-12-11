defmodule Expert.EngineTest do
  use ExUnit.Case, async: false
  use Patch

  alias Expert.Engine

  import ExUnit.CaptureIO

  @test_base_dir "test_engine_builds"

  setup do
    File.mkdir_p!(@test_base_dir)

    patch(Engine, :base_dir, @test_base_dir)

    patch(System, :halt, fn _code -> :ok end)

    on_exit(fn ->
      if File.exists?(@test_base_dir) do
        File.rm_rf!(@test_base_dir)
      end
    end)

    :ok
  end

  describe "run/1 - ls subcommand" do
    test "lists nothing when no engine builds exist" do
      output =
        capture_io(fn ->
          Engine.run(["ls"])
        end)

      assert output =~ "No engine builds found."
    end

    test "lists engine directories" do
      File.mkdir_p!(Path.join(@test_base_dir, "0.1.0"))
      File.mkdir_p!(Path.join(@test_base_dir, "0.2.0"))

      output =
        capture_io(fn ->
          Engine.run(["ls"])
        end)

      assert output =~ "0.1.0"
      assert output =~ "0.2.0"
    end
  end

  describe "run/1 - clean subcommand with --force" do
    test "deletes all engine directories without prompting" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      dir2 = Path.join(@test_base_dir, "0.2.0")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)

      assert File.exists?(dir1)
      assert File.exists?(dir2)

      output =
        capture_io(fn ->
          Engine.run(["clean", "--force"])
        end)

      assert output =~ "Deleted"
      assert output =~ dir1
      assert output =~ dir2

      refute File.exists?(dir1)
      refute File.exists?(dir2)
    end

    test "deletes all engine directories with -f short flag" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      capture_io(fn ->
        Engine.run(["clean", "-f"])
      end)

      refute File.exists?(dir1)
    end

    test "handles deletion errors gracefully" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      # Mock File.rm_rf to return an error
      patch(File, :rm_rf, fn _path ->
        {:error, :eacces, dir1}
      end)

      output =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            Engine.run(["clean", "--force"])
          end)
        end)

      assert output =~ "Error deleting"
      assert output =~ dir1
    end
  end

  describe "run/1 - clean subcommand interactive mode" do
    test "deletes directory when user confirms with 'y'" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      assert File.exists?(dir1)

      capture_io([input: "y\n"], fn ->
        Engine.run(["clean"])
      end)

      refute File.exists?(dir1)
    end

    test "deletes directory when user confirms with 'yes'" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      capture_io([input: "yes\n"], fn ->
        Engine.run(["clean"])
      end)

      refute File.exists?(dir1)
    end

    test "deletes directory when user presses enter (default yes)" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      capture_io([input: "\n"], fn ->
        Engine.run(["clean"])
      end)

      refute File.exists?(dir1)
    end

    test "keeps directory when user declines with 'n'" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      capture_io([input: "n\n"], fn ->
        Engine.run(["clean"])
      end)

      assert File.exists?(dir1)
    end

    test "keeps directory when user declines with 'no'" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      capture_io([input: "no\n"], fn ->
        Engine.run(["clean"])
      end)

      assert File.exists?(dir1)
    end

    test "keeps directory when user enters any other text" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      capture_io([input: "maybe\n"], fn ->
        Engine.run(["clean"])
      end)

      assert File.exists?(dir1)
    end

    test "handles multiple directories with mixed responses" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      dir2 = Path.join(@test_base_dir, "0.2.0")
      dir3 = Path.join(@test_base_dir, "0.3.0")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      File.mkdir_p!(dir3)

      # Answer yes to first, no to second, yes to third
      capture_io([input: "y\nn\nyes\n"], fn ->
        Engine.run(["clean"])
      end)

      refute File.exists?(dir1)
      assert File.exists?(dir2)
      refute File.exists?(dir3)
    end

    test "prints message when no engine builds exist" do
      output =
        capture_io([input: "\n"], fn ->
          Engine.run(["clean"])
        end)

      assert output =~ "No engine builds found."
    end
  end

  describe "run/1 - help and unknown commands" do
    test "prints help for unknown subcommand" do
      output =
        capture_io(fn ->
          Engine.run(["unknown"])
        end)

      assert output =~ "Expert Engine Management"
    end
  end
end
