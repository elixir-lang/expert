defmodule Expert.EngineTest do
  use ExUnit.Case, async: false
  use Patch

  alias Expert.Engine

  import ExUnit.CaptureIO

  @moduletag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    patch(Engine, :base_dir, tmp_dir)

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

    test "lists engine directories", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "0.1.0/foobar"))
      File.mkdir_p!(Path.join(tmp_dir, "0.2.0/foobar"))

      output =
        capture_io(fn ->
          exit_code = Engine.run(["ls"])
          assert exit_code == 0
        end)

      assert output =~ "0.1.0"
      assert output =~ "0.2.0"
    end

    test "shows help with --help and -h flags" do
      for flag <- ["--help", "-h"] do
        output =
          capture_io(fn ->
            exit_code = Engine.run(["ls", flag])
            assert exit_code == 0
          end)

        assert output =~ "List Engine Builds"
        assert output =~ "expert engine ls"
      end
    end
  end

  describe "run/1 - clean subcommand with --force" do
    test "deletes all engine directories with --force and -f flags", %{tmp_dir: tmp_dir} do
      for flag <- ["--force", "-f"] do
        dir1 = Path.join(tmp_dir, "0.1.0/foobar")
        dir2 = Path.join(tmp_dir, "0.2.0/foobar")
        File.mkdir_p!(dir1)
        File.mkdir_p!(dir2)

        assert File.exists?(dir1)
        assert File.exists?(dir2)

        output =
          capture_io(fn ->
            exit_code = Engine.run(["clean", flag])
            assert exit_code == 0
          end)

        assert output =~ "Deleted"
        assert output =~ dir1
        assert output =~ dir2

        refute File.exists?(dir1)
        refute File.exists?(dir2)
      end
    end

    test "stops deleting after first error and returns error code 1", %{tmp_dir: tmp_dir} do
      dir1 = Path.join(tmp_dir, "0.1.0/foobar")
      dir2 = Path.join(tmp_dir, "0.2.0/foobar")
      dir3 = Path.join(tmp_dir, "0.2.0/bazbeau")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      File.mkdir_p!(dir3)

      # Track which directories were attempted
      {:ok, agent_pid} = Agent.start_link(fn -> [] end)

      # Fail on the second directory
      patch(File, :rm_rf, fn path ->
        :ok = Agent.update(agent_pid, fn list -> [path | list] end)

        cond do
          String.ends_with?(path, "0.1.0/foobar") -> {:ok, []}
          String.ends_with?(path, "0.2.0/bazbeau") -> {:error, :eacces, path}
          true -> {:ok, []}
        end
      end)

      output =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            exit_code = Engine.run(["clean", "--force"])
            assert exit_code == 1
          end)
        end)

      assert output =~ "Error deleting"
      assert output =~ dir3

      # Should only attempt dir1 and dir2, not dir3
      attempted_dirs =
        agent_pid
        |> Agent.get(& &1)
        |> Enum.reverse()

      assert length(attempted_dirs) == 2
      assert Enum.at(attempted_dirs, 0) =~ "0.1.0/foobar"
      assert Enum.at(attempted_dirs, 1) =~ "0.2.0/foobar"
    end
  end

  describe "run/1 - clean subcommand interactive mode" do
    test "deletes directory when user confirms", %{tmp_dir: tmp_dir} do
      for input <- ["y\n", "yes\n", "\n"] do
        dir1 = Path.join(tmp_dir, "0.1.0/foobar")
        File.mkdir_p!(dir1)

        assert File.exists?(dir1)

        capture_io([input: input], fn ->
          exit_code = Engine.run(["clean"])
          assert exit_code == 0
        end)

        refute File.exists?(dir1)
      end
    end

    test "keeps directory when user declines", %{tmp_dir: tmp_dir} do
      for input <- ["n\n", "no\n"] do
        dir1 = Path.join(tmp_dir, "0.1.0/foobar")
        File.mkdir_p!(dir1)

        capture_io([input: input], fn ->
          exit_code = Engine.run(["clean"])
          assert exit_code == 0
        end)

        assert File.exists?(dir1)
      end
    end

    test "keeps directory when user enters any other text", %{tmp_dir: tmp_dir} do
      dir1 = Path.join(tmp_dir, "0.1.0/foobar")
      File.mkdir_p!(dir1)

      capture_io([input: "maybe\n"], fn ->
        exit_code = Engine.run(["clean"])
        assert exit_code == 0
      end)

      assert File.exists?(dir1)
    end

    test "handles multiple directories with mixed responses", %{tmp_dir: tmp_dir} do
      dir1 = Path.join(tmp_dir, "0.1.0/foobar")
      dir2 = Path.join(tmp_dir, "0.2.0/foobar")
      dir3 = Path.join(tmp_dir, "0.2.0/bazbeau")
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

    test "stops deleting after first error and returns error code 1", %{tmp_dir: tmp_dir} do
      dir1 = Path.join(tmp_dir, "0.1.0/foobar")
      dir2 = Path.join(tmp_dir, "0.2.0/foobar")
      dir3 = Path.join(tmp_dir, "0.2.0/bazbeau")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      File.mkdir_p!(dir3)

      # Track which directories were attempted
      {:ok, agent_pid} = Agent.start_link(fn -> [] end)

      # Fail on the second directory
      patch(File, :rm_rf, fn path ->
        :ok = Agent.update(agent_pid, fn list -> [path | list] end)

        cond do
          String.ends_with?(path, "0.1.0/foobar") -> {:ok, []}
          String.ends_with?(path, "0.2.0/bazbeau") -> {:error, :eacces, path}
          true -> {:ok, []}
        end
      end)

      output =
        capture_io(:stderr, fn ->
          capture_io([input: "y\ny\ny\n"], fn ->
            exit_code = Engine.run(["clean"])
            assert exit_code == 1
          end)
        end)

      assert output =~ "Error deleting"

      # Should only attempt dir1 and dir2, not dir3
      attempted_dirs =
        agent_pid
        |> Agent.get(& &1)
        |> Enum.reverse()

      assert length(attempted_dirs) == 2
      assert Enum.at(attempted_dirs, 0) =~ "0.1.0"
      assert Enum.at(attempted_dirs, 1) =~ "0.2.0"
    end
  end

  describe "run/1 - help and unknown commands" do
    test "prints error for unknown subcommand" do
      output =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            exit_code = Engine.run(["unknown"])
            assert exit_code == 1
          end)
        end)

      assert output =~ "Error: Unknown subcommand 'unknown'"
      assert output =~ "Run 'expert engine --help' for usage information"
    end

    test "prints help when no subcommand provided" do
      output =
        capture_io(fn ->
          exit_code = Engine.run([])
          assert exit_code == 0
        end)

      assert output =~ "Expert Engine Management"
    end
  end
end
