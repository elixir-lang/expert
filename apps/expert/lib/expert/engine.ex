defmodule Expert.Engine do
  @moduledoc """
  Utilities for managing Expert engine builds.

  When Expert builds the engine for a project using Mix.install, it caches
  the build in the user data directory. If engine dependencies change (e.g.,
  in nightly builds), Mix.install may not know to rebuild, causing errors.

  This module provides functions to inspect and clean these cached builds.
  """

  @doc """
  Runs engine management commands based on parsed arguments.

  Returns the exit code for the command. Clean operations will stop at the
  first deletion error and return exit code 1.
  """

  @success_code 0
  @error_code 1

  @help_options ["-h", "--help"]

  @spec run([String.t()]) :: non_neg_integer()
  def run(args) do
    {opts, subcommand, _invalid} =
      OptionParser.parse(args,
        strict: [force: :boolean],
        aliases: [f: :force]
      )

    case subcommand do
      ["ls"] -> list_engines()
      ["ls", options] when options in @help_options -> print_ls_help()
      ["clean"] -> clean_engines(opts)
      ["clean", options] when options in @help_options -> print_clean_help()
      _ -> print_help()
    end
  end

  @spec list_engines() :: non_neg_integer()
  defp list_engines do
    case get_engine_dirs() do
      [] ->
        IO.puts("No engine builds found.")
        print_location_info()

      dirs ->
        Enum.each(dirs, &IO.puts/1)
    end

    @success_code
  end

  @spec clean_engines(keyword()) :: non_neg_integer()
  defp clean_engines(opts) do
    case get_engine_dirs() do
      [] ->
        IO.puts("No engine builds found.")
        print_location_info()
        @success_code

      dirs ->
        if opts[:force] do
          clean_all_force(dirs)
        else
          clean_interactive(dirs)
        end
    end
  end

  defp base_dir do
    base = :filename.basedir(:user_data, ~c"Expert")
    to_string(base)
  end

  defp get_engine_dirs do
    base = base_dir()

    if File.exists?(base) do
      base
      |> File.ls!()
      |> Enum.map(&Path.join(base, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.sort()
    else
      []
    end
  end

  @spec clean_all_force([String.t()]) :: non_neg_integer()
  # Deletes all directories without prompting. Stops on first error and returns 1.
  defp clean_all_force(dirs) do
    result =
      Enum.reduce_while(dirs, :ok, fn dir, _acc ->
        case File.rm_rf(dir) do
          {:ok, _} ->
            IO.puts("Deleted #{dir}")
            {:cont, :ok}

          {:error, reason, file} ->
            IO.puts(:stderr, "Error deleting #{file}: #{inspect(reason)}")
            {:halt, :error}
        end
      end)

    case result do
      :ok -> @success_code
      :error -> @error_code
    end
  end

  @spec clean_interactive([String.t()]) :: non_neg_integer()
  # Prompts the user for each directory deletion. Stops on first error and returns 1.
  defp clean_interactive(dirs) do
    result =
      Enum.reduce_while(dirs, :ok, fn dir, _acc ->
        answer = prompt_delete(dir)

        if answer do
          case File.rm_rf(dir) do
            {:ok, _} ->
              {:cont, :ok}

            {:error, reason, file} ->
              IO.puts(:stderr, "Error deleting #{file}: #{inspect(reason)}")
              {:halt, :error}
          end
        else
          {:cont, :ok}
        end
      end)

    case result do
      :ok -> @success_code
      :error -> @error_code
    end
  end

  defp prompt_delete(dir) do
    IO.puts(["Delete #{dir}", IO.ANSI.red(), "?", IO.ANSI.reset(), " [Yn] "])

    input =
      ""
      |> IO.gets()
      |> String.trim()
      |> String.downcase()

    case input do
      "" -> true
      "y" -> true
      "yes" -> true
      _ -> false
    end
  end

  defp print_location_info do
    IO.puts("\nEngine builds are stored in: #{base_dir()}")
  end

  @spec print_help() :: non_neg_integer()
  defp print_help do
    IO.puts("""
    Expert Engine Management

    Manage cached engine builds created by Mix.install. Use these commands
    to resolve dependency errors or free up disk space.

    USAGE:
        expert engine <subcommand>

    SUBCOMMANDS:
        ls              List all engine build directories
        clean           Interactively delete engine build directories

    Use 'expert engine <subcommand> --help' for more information on a specific command.

    EXAMPLES:
        expert engine ls
        expert engine clean
    """)

    @success_code
  end

  @spec print_ls_help() :: non_neg_integer()
  defp print_ls_help do
    IO.puts("""
    List Engine Builds

    List all cached engine build directories.

    USAGE:
        expert engine ls

    EXAMPLES:
        expert engine ls
    """)

    @success_code
  end

  @spec print_clean_help() :: non_neg_integer()
  defp print_clean_help do
    IO.puts("""
    Clean Engine Builds

    Interactively delete cached engine build directories. By default, you will
    be prompted to confirm deletion of each build. Use --force to skip prompts.

    USAGE:
        expert engine clean [options]

    OPTIONS:
        -f, --force     Delete all builds without prompting

    EXAMPLES:
        expert engine clean
        expert engine clean --force
    """)

    @success_code
  end
end
