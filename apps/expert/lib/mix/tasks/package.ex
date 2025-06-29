defmodule Mix.Tasks.Package do
  @moduledoc """
  Creates the Expert application's artifacts

  Expert does some strange things to its own code via namespacing, but because it does so, we can't
  use standard build tooling. The app names of its modules and dependencies are changed, so `mix install`
  won't realize that the correct apps are installed. It uses two different VMs, so making an `escript`
  will fail, as the second VM needs to find Expert's modules _somewhere. Releases seem ideal, and we
  used them for a while, but they need to match the _exact_ Elixir and Erlang versions they were compiled on,
  right down to the patch level. This is much, much too strict for a project that needs to be able to run
  on a variety of elixir / erlang versions.

  An ideal packaging system will have the following properties:

    * It creates a self contained artifact directory
    * It will run under a variety of versions of Elixir and Erlang
    * It allows namespaced apps to run
    * It allows multiple VMs to find elixir's modules
    * It allows us to package non-elixir resources (mainly launcher scripts) and access them during runtime

  This packaging system meets all of the above parameters.
  It works by examining the server app's dependencies, namespacing what's required and then packaging them
  in to [Erlang archive files](https://www.erlang.org/doc/man/code.html#loading-of-code-from-archive-files)
  in a `lib` directory. Similarly, the configuration is copied to a `config` directory, and the launcher
  scripts are copied to a `bin` directory.

  The end result is a release-like filesystem, but without a lot of the erlang booting stuff. Bootstrapping
  accomplished by simple scripts that reside in the project's `/bin` directory, and the `Expert.Boot`
  module, which loads applications and their modules.

  ## Command line options

  * `--path` - The package will be written to the path given. Defaults to `./build/dev/expert`. If the
    `--zip` option is specified, The name of the zip file is determined by the last entry of the path.
    For example, if the `--path` option is `_build/dev/output`, then the name of the zip file will be
    `output.zip`.
  * `--zip`  - The resulting package will be zipped. The zip file will be placed in the current directory,
    and the package directory will be deleted


  ## Directory structure
  ```text
  bin/
    start_expert.sh
    debug_shell.sh
  lib/
    xp_forge.sh
    xp_engine.sh
    xp_expert.ez
    ...
  config/
    config.exs
    dev.exs
    prod.exs
    test.exs
    runtime.exs
  priv/
    port_wrapper.sh
    ...
  consolidated/
    Elixir.(consolidated protocol module).beam
  ```

  On boot, the `ERL_LIBS` environment variable is set to the `lib` directory so all of the `.ez` files are
  picked up by the code server. Similarly, the `config`, `consolidated` and `priv` directories are added
  to the code search path with the `-pa` argument.
  """

  alias Forge.VM.Versions
  alias Forge.Namespace

  @options [
    strict: [
      path: :string,
      zip: :boolean
    ]
  ]

  @execute_permisson 0o755

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, @options)
    default_path = Path.join([Mix.Project.build_path(), "package", "expert"])
    package_root = Keyword.get(opts, :path, default_path)

    rebuild_on_version_change(package_root)

    Mix.Task.run(:compile)
    Mix.Shell.IO.info("Assembling build in #{package_root}")
    File.mkdir_p!(package_root)

    {:ok, scratch_directory} = prepare(package_root)

    build_archives(package_root, scratch_directory)
    copy_consolidated_beams(package_root)
    copy_launchers(package_root)
    copy_priv_files(package_root)
    copy_config(package_root)
    write_vm_versions(package_root)

    File.rm_rf!(scratch_directory)

    if Keyword.get(opts, :zip, false) do
      zip(package_root)
      File.rm_rf(package_root)
    end
  end

  defp rebuild_on_version_change(package_root) do
    %{elixir: elixir_current, erlang: erlang_current} = Versions.current()

    with {:ok, %{elixir: elixir_compiled, erlang: erlang_compiled}} <-
           Versions.read(priv_path(package_root)) do
      if elixir_compiled != elixir_current or erlang_compiled != erlang_current do
        Code.put_compiler_option(:ignore_module_conflict, true)
        Mix.Shell.IO.error("The version of elixir or erlang has changed. Forcing recompilation.")
        File.rm_rf!(package_root)
        Mix.Task.clear()
        Mix.Task.run(:clean, ~w(--deps))
      end
    end
  end

  defp prepare(package_root) do
    scratch_directory = Path.join(package_root, "scratch")
    File.mkdir(scratch_directory)

    [Mix.Project.build_path(), "lib"]
    |> Path.join()
    |> File.cp_r!(Path.join(scratch_directory, "lib"))

    Mix.Task.run(:namespace, [scratch_directory])
    {:ok, scratch_directory}
  end

  defp build_archives(package_root, scratch_directory) do
    scratch_directory
    |> target_path()
    |> File.mkdir_p!()

    app_dirs = app_dirs(scratch_directory)

    Enum.each(app_dirs, fn {app_name, path} ->
      create_archive(package_root, app_name, path)
    end)
  end

  defp app_dirs(scratch_directory) do
    lib_directory = Path.join(scratch_directory, "lib")
    server_deps = server_deps()

    lib_directory
    |> File.ls!()
    |> Enum.filter(&(&1 in server_deps))
    |> Map.new(fn dir ->
      app_name = Path.basename(dir)
      {app_name, Path.join([scratch_directory, "lib", dir])}
    end)
  end

  defp create_archive(package_root, app_name, app_path) do
    file_list = file_list(app_name, app_path)
    zip_path = Path.join([target_path(package_root), "#{app_name}.ez"])

    {:ok, _} =
      zip_path
      |> String.to_charlist()
      |> :zip.create(file_list, uncompress: [~c".beam"])

    :ok
  end

  defp file_list(app_name, app_path) do
    File.cd!(app_path, fn ->
      beams = Path.wildcard("ebin/*.{app,beam}")
      priv = Path.wildcard("priv/**/*", match_dot: true)

      Enum.reduce(beams ++ priv, [], fn relative_path, acc ->
        case File.read(relative_path) do
          {:ok, contents} ->
            zip_relative_path =
              app_name
              |> Path.join(relative_path)
              |> String.to_charlist()

            [{zip_relative_path, contents} | acc]

          {:error, _} ->
            acc
        end
      end)
    end)
  end

  defp copy_consolidated_beams(package_root) do
    beams_dest_dir = Path.join(package_root, "consolidated")

    File.mkdir_p!(beams_dest_dir)

    File.cp_r!(Mix.Project.consolidation_path(), beams_dest_dir)

    beams_dest_dir
    |> File.ls!()
    |> Enum.each(fn relative_path ->
      absolute_path = Path.join(beams_dest_dir, relative_path)
      Namespace.Transform.Beams.apply(absolute_path)
    end)
  end

  defp copy_launchers(package_root) do
    launcher_source_dir =
      Mix.Project.project_file()
      |> Path.dirname()
      |> Path.join("bin")

    launcher_dest_dir = Path.join(package_root, "bin")

    File.mkdir_p!(launcher_dest_dir)
    File.cp_r!(launcher_source_dir, launcher_dest_dir)

    launcher_dest_dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      File.chmod!(path, @execute_permisson)
    end)
  end

  defp target_path(scratch_directory) do
    Path.join([scratch_directory, "lib"])
  end

  defp server_deps do
    deps_apps =
      if Mix.Project.get() == Expert.MixProject do
        Mix.Project.deps_apps()
      else
        server_path = Mix.Project.deps_paths()[:expert]

        Mix.Project.in_project(:expert, server_path, fn _ ->
          Mix.Project.deps_apps()
        end)
      end

    deps =
      Enum.map(deps_apps, fn app_module ->
        app_module
        |> Namespace.Module.apply()
        |> to_string()
      end)

    server_dep =
      :expert
      |> Namespace.Module.apply()
      |> to_string()

    [server_dep | deps]
  end

  defp copy_config(package_root) do
    config_source =
      Mix.Project.config()[:config_path]
      |> Path.absname()
      |> Path.dirname()

    config_dest = Path.join(package_root, "config")
    File.mkdir_p!(config_dest)
    File.cp_r!(config_source, config_dest)

    Namespace.Transform.Configs.apply_to_all(config_dest)
  end

  @priv_apps [:engine]

  defp copy_priv_files(package_root) do
    priv_dest_dir = priv_path(package_root)

    Enum.each(@priv_apps, fn app_name ->
      case priv_dir(app_name) do
        {:ok, priv_source_dir} ->
          File.cp_r!(priv_source_dir, priv_dest_dir)

        _ ->
          :ok
      end
    end)
  end

  defp write_vm_versions(package_root) do
    package_root
    |> priv_path()
    |> Versions.write()
  end

  defp zip(package_root) do
    package_name = Path.basename(package_root)

    zip_output = Path.join(File.cwd!(), "#{package_name}.zip")

    package_root
    |> Path.dirname()
    |> File.cd!(fn ->
      System.cmd("zip", ["-r", zip_output, package_name])
    end)
  end

  defp priv_dir(app) do
    case :code.priv_dir(app) do
      {:error, _} ->
        :error

      path ->
        normalized =
          path
          |> List.to_string()
          |> normalize_path()

        {:ok, normalized}
    end
  end

  defp normalize_path(path) do
    case File.read_link(path) do
      {:ok, orig} ->
        path
        |> Path.dirname()
        |> Path.join(orig)
        |> Path.expand()
        |> Path.absname()

      _ ->
        path
    end
  end

  defp priv_path(package_root) do
    Path.join(package_root, "priv")
  end
end
