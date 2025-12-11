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

  Returns :ok and halts the system after executing the command.
  """
  @spec run([String.t()]) :: no_return()
  def run(args) do
    {opts, subcommand, _invalid} =
      OptionParser.parse(args,
        strict: [force: :boolean],
        aliases: [f: :force]
      )

    case subcommand do
      ["ls"] -> list_engines()
      ["clean"] -> clean_engines(opts)
      _ -> print_help()
    end
  end

  @spec list_engines() :: no_return()
  defp list_engines do
    case get_engine_dirs() do
      [] ->
        IO.puts("No engine builds found.")
        print_location_info()

      dirs ->
        Enum.each(dirs, &IO.puts/1)
    end

    System.halt(0)
  end

  @spec clean_engines(keyword()) :: no_return()
  defp clean_engines(opts) do
    case get_engine_dirs() do
      [] ->
        IO.puts("No engine builds found.")
        print_location_info()
        System.halt(0)

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

  @spec clean_all_force([String.t()]) :: no_return()
  defp clean_all_force(dirs) do
    Enum.each(dirs, fn dir ->
      case File.rm_rf(dir) do
        {:ok, _} ->
          IO.puts("Deleted #{dir}")

        {:error, reason, file} ->
          IO.puts(:stderr, "Error deleting #{file}: #{inspect(reason)}")
      end
    end)

    System.halt(0)
  end

  @spec clean_interactive([String.t()]) :: no_return()
  defp clean_interactive(dirs) do
    Enum.each(dirs, fn dir ->
      answer = prompt_delete(dir)

      if answer do
        case File.rm_rf(dir) do
          {:ok, _} ->
            :ok

          {:error, reason, file} ->
            IO.puts(:stderr, "Error deleting #{file}: #{inspect(reason)}")
        end
      end
    end)

    System.halt(0)
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

  @spec print_help() :: no_return()
  defp print_help do
    IO.puts("""
    Expert Engine Management

    Manage cached engine builds created by Mix.install. Use these commands
    to resolve dependency errors or free up disk space.

    USAGE:
        expert engine <subcommand> [options]

    SUBCOMMANDS:
        ls              List all engine build directories
        clean           Interactively delete engine build directories

    OPTIONS:
        -f, --force     Delete all builds without prompting (clean only)

    EXAMPLES:
        expert engine ls
        expert engine clean
        expert engine clean --force
    """)

    System.halt(0)
  end
end
