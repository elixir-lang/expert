defmodule Expert.PortTest do
  use ExUnit.Case, async: false

  alias Expert.Port
  alias Forge.Test.Fixtures

  setup do
    original_env = %{
      "SHELL" => System.get_env("SHELL"),
      "EXPERT_PATH_SHELL_MODE" => System.get_env("EXPERT_PATH_SHELL_MODE"),
      "EXPERT_ARGS_FILE" => System.get_env("EXPERT_ARGS_FILE")
    }

    on_exit(fn ->
      Enum.each(original_env, fn {key, value} ->
        if value do
          System.put_env(key, value)
        else
          System.delete_env(key)
        end
      end)
    end)

    :ok
  end

  if match?({:unix, _}, :os.type()) do
    @tag :tmp_dir
    test "uses a non-interactive login shell by default", %{tmp_dir: tmp_dir} do
      args = capture_lookup_args(tmp_dir)

      assert ["-l", "-c", _cmd] = args
    end

    @tag :tmp_dir
    test "supports interactive shell lookup as an opt-in", %{tmp_dir: tmp_dir} do
      System.put_env("EXPERT_PATH_SHELL_MODE", "interactive")

      args = capture_lookup_args(tmp_dir)

      assert ["-i", "-l", "-c", _cmd] = args
    end

    @tag :tmp_dir
    test "falls back to non-interactive login shell for unknown shell mode", %{tmp_dir: tmp_dir} do
      System.put_env("EXPERT_PATH_SHELL_MODE", "bogus")

      args = capture_lookup_args(tmp_dir)

      assert ["-l", "-c", _cmd] = args
    end
  end

  defp capture_lookup_args(tmp_dir) do
    args_file = Path.join(tmp_dir, "shell-args.txt")
    shell_path = write_shell_probe(tmp_dir)

    System.put_env("EXPERT_ARGS_FILE", args_file)
    System.put_env("SHELL", shell_path)

    project = Fixtures.project()

    assert {:ok, _elixir, _env} = Port.find_project_executable(project, "elixir")

    args_file
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp write_shell_probe(tmp_dir) do
    shell_path = Path.join(tmp_dir, "zsh")

    File.write!(
      shell_path,
      """
      #!/bin/sh
      printf '%s\\n' "$@" > "$EXPERT_ARGS_FILE"
      printf '__EXPERT_PATH__:%s:__EXPERT_PATH__' "$PATH"
      """
    )

    File.chmod!(shell_path, 0o755)
    shell_path
  end
end
