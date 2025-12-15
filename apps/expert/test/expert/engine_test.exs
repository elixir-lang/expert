defmodule Expert.EngineTest do
  use ExUnit.Case, async: false
  use Patch

  alias Expert.Engine

  import ExUnit.CaptureIO

  @test_base_dir "test_engine_builds"

  setup do
    File.mkdir_p!(@test_base_dir)

    patch(Engine, :base_dir, @test_base_dir)

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
          exit_code = Engine.run(["ls"])
          assert exit_code == 0
        end)

      assert output =~ "No engine builds found."
    end

    test "lists engine directories" do
      File.mkdir_p!(Path.join(@test_base_dir, "0.1.0"))
      File.mkdir_p!(Path.join(@test_base_dir, "0.2.0"))

      output =
        capture_io(fn ->
          exit_code = Engine.run(["ls"])
          assert exit_code == 0
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
          exit_code = Engine.run(["clean", "--force"])
          assert exit_code == 0
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
        exit_code = Engine.run(["clean", "-f"])
        assert exit_code == 0
      end)

      refute File.exists?(dir1)
    end

    test "stops on first deletion error and returns error code 1" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      # Mock File.rm_rf to return an error
      patch(File, :rm_rf, fn _path ->
        {:error, :eacces, dir1}
      end)

      output =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            exit_code = Engine.run(["clean", "--force"])
            assert exit_code == 1
          end)
        end)

      assert output =~ "Error deleting"
      assert output =~ dir1
    end

    test "stops deleting after first error" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      dir2 = Path.join(@test_base_dir, "0.2.0")
      dir3 = Path.join(@test_base_dir, "0.3.0")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      File.mkdir_p!(dir3)

      # Track which directories were attempted
      {:ok, agent_pid} = Agent.start_link(fn -> [] end)

      # Fail on the second directory
      patch(File, :rm_rf, fn path ->
        :ok = Agent.update(agent_pid, fn list -> [path | list] end)

        cond do
          String.ends_with?(path, "0.1.0") -> {:ok, []}
          String.ends_with?(path, "0.2.0") -> {:error, :eacces, path}
          true -> {:ok, []}
        end
      end)

      capture_io(:stderr, fn ->
        capture_io(fn ->
          exit_code = Engine.run(["clean", "--force"])
          assert exit_code == 1
        end)
      end)

      # Should only attempt dir1 and dir2, not dir3
      attempted_dirs =
        agent
        |> Agent.get(& &1)
        |> Enum.reverse()

      assert length(attempted_dirs) == 2
      assert Enum.at(attempted_dirs, 0) =~ "0.1.0"
      assert Enum.at(attempted_dirs, 1) =~ "0.2.0"
    end
  end

  describe "run/1 - clean subcommand interactive mode" do
    test "deletes directory when user confirms with 'y'" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      assert File.exists?(dir1)

      capture_io([input: "y\n"], fn ->
        exit_code = Engine.run(["clean"])
        assert exit_code == 0
      end)

      refute File.exists?(dir1)
    end

    test "deletes directory when user confirms with 'yes'" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      capture_io([input: "yes\n"], fn ->
        exit_code = Engine.run(["clean"])
        assert exit_code == 0
      end)

      refute File.exists?(dir1)
    end

    test "deletes directory when user presses enter (default yes)" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      capture_io([input: "\n"], fn ->
        exit_code = Engine.run(["clean"])
        assert exit_code == 0
      end)

      refute File.exists?(dir1)
    end

    test "keeps directory when user declines with 'n'" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      capture_io([input: "n\n"], fn ->
        exit_code = Engine.run(["clean"])
        assert exit_code == 0
      end)

      assert File.exists?(dir1)
    end

    test "keeps directory when user declines with 'no'" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      capture_io([input: "no\n"], fn ->
        exit_code = Engine.run(["clean"])
        assert exit_code == 0
      end)

      assert File.exists?(dir1)
    end

    test "keeps directory when user enters any other text" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      capture_io([input: "maybe\n"], fn ->
        exit_code = Engine.run(["clean"])
        assert exit_code == 0
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
        exit_code = Engine.run(["clean"])
        assert exit_code == 0
      end)

      refute File.exists?(dir1)
      assert File.exists?(dir2)
      refute File.exists?(dir3)
    end

    test "prints message when no engine builds exist" do
      output =
        capture_io([input: "\n"], fn ->
          exit_code = Engine.run(["clean"])
          assert exit_code == 0
        end)

      assert output =~ "No engine builds found."
    end

    test "stops on first deletion error in interactive mode and returns error code 1" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      File.mkdir_p!(dir1)

      patch(File, :rm_rf, fn _path ->
        {:error, :eacces, dir1}
      end)

      output =
        capture_io(:stderr, fn ->
          capture_io([input: "y\n"], fn ->
            exit_code = Engine.run(["clean"])
            assert exit_code == 1
          end)
        end)

      assert output =~ "Error deleting"
    end

    test "stops deleting after first error in interactive mode" do
      dir1 = Path.join(@test_base_dir, "0.1.0")
      dir2 = Path.join(@test_base_dir, "0.2.0")
      dir3 = Path.join(@test_base_dir, "0.3.0")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      File.mkdir_p!(dir3)

      # Track which directories were attempted
      {:ok, agent_pid} = Agent.start_link(fn -> [] end)

      # Fail on the second directory
      patch(File, :rm_rf, fn path ->
        :ok = Agent.update(agent_pid, fn list -> [path | list] end)

        cond do
          String.ends_with?(path, "0.1.0") -> {:ok, []}
          String.ends_with?(path, "0.2.0") -> {:error, :eacces, path}
          true -> {:ok, []}
        end
      end)

      capture_io(:stderr, fn ->
        capture_io([input: "y\ny\ny\n"], fn ->
          exit_code = Engine.run(["clean"])
          assert exit_code == 1
        end)
      end)

      attempted_dirs =
        agent
        |> Agent.get(& &1)
        |> Enum.reverse()

      assert length(attempted_dirs) == 2
      assert Enum.at(attempted_dirs, 0) =~ "0.1.0"
      assert Enum.at(attempted_dirs, 1) =~ "0.2.0"
    end
  end

  describe "run/1 - help and unknown commands" do
    test "prints help for unknown subcommand" do
      output =
        capture_io(fn ->
          exit_code = Engine.run(["unknown"])
          assert exit_code == 0
        end)

      assert output =~ "Expert Engine Management"
    end
  end
end
