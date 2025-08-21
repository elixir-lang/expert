defmodule Mix.Tasks.Namespace do
  @moduledoc """
  This task will apply namespacing to a set of .beam and .app files in the given directory.

  Primarily works on a list of application and a list of "module roots".

  A module root is the first segment of an Elixir module, e.g., "Foo" in "Foo.Bar.Baz".

  The initial list of apps and roots (before additional inclusions and exclusions) are derived from
  fetching the projects deps via `Mix.Project.deps_apps/0`. From there, each dependency's modules are
  fetched via `:application.get_key(dep_app, :modules)`.

  ## Options

  * `--directory` - The active working directory (required)
  * `--[no-]dot-apps` - Whether to namespace application names and .app files at all. Useful to disable if you dont need to start the project like a normal application. Defaults to false.
  * `--include-app` - Adds the given application to the list of applications to namespace.
  * `--exclude-app` - Removes the given application from the list of applications to namespace.
  * `--include-root` - Adds the given module "root" to the list of "roots" to namespace.
  * `--exclude-root` - Removes the given module "root" from the list of "roots" to namespace.


  ## Usage

  ```bash
  mix namespace --directory _build/prod --include-app engine --include-root Engine --exclude-app namespace --dot-apps
  mix namespace --directory _build/dev --include-app expert --exclude-root Expert --exclude-app burrito --exclude-app namespace --exclude-root Jason --include-root Engine
  ```
  """
  alias Forge.Ast
  alias Forge.Namespace.Transform
  use Mix.Task

  @dev_deps [:patch, :burrito]
  # Unless explicitly added, nimble_parsec won't show up as a loaded app
  # and will therefore not be namespaced.
  @no_app_deps [:nimble_parsec]

  # These app names and root modules are strings to avoid them being namespaced
  # by this task. Plugin discovery uses this task, which happens after
  # namespacing.
  @extra_apps %{
    "engine" => "Engine",
    "expert" => "Expert",
    "forge" => "Forge"
  }

  require Logger

  def run(argv) do
    {options, _rest} =
      OptionParser.parse!(argv,
        strict: [
          directory: :string,
          dot_apps: :boolean,
          include_app: :keep,
          include_root: :keep,
          exclude_app: :keep,
          exclude_root: :keep
        ]
      )

    base_directory = Keyword.fetch!(options, :directory)

    # Ensure we cache the loaded apps at the time of namespacing
    # Otherwise only the @extra_apps will be cached
    init()

    include_apps = options |> Keyword.get_values(:include_app) |> Enum.map(&String.to_atom/1)
    include_roots = options |> Keyword.get_values(:include_root) |> Enum.map(&normalize_root/1)
    exclude_apps = options |> Keyword.get_values(:exclude_app) |> Enum.map(&String.to_atom/1)
    exclude_roots = options |> Keyword.get_values(:exclude_root) |> Enum.map(&normalize_root/1)

    apps = Enum.uniq(Mix.Project.deps_apps() ++ include_apps) -- exclude_apps

    roots_from_apps =
      apps |> root_modules_for_apps() |> Map.values() |> List.flatten() |> Enum.uniq()

    roots = (roots_from_apps ++ include_roots) -- exclude_roots

    opts = [apps: apps, roots: roots, do_apps: options[:dot_apps]]

    Transform.Apps.apply_to_all(base_directory, opts)
    Transform.Beams.apply_to_all(base_directory, opts)
    Transform.Scripts.apply_to_all(base_directory, opts)
    # The boot file transform just turns script files into boot files
    # so it must come after the script file transform
    Transform.Boots.apply_to_all(base_directory, opts)
    Transform.Configs.apply_to_all(base_directory, opts)
    Transform.AppDirectories.apply_to_all(base_directory, opts)

    if options[:dot_apps] do
      Transform.AppDirectories.apply_to_all(base_directory, opts)
    end
  end

  def normalize_root(module), do: Module.concat([module])

  def app_names do
    Map.keys(app_to_root_modules())
  end

  def root_modules do
    app_to_root_modules()
    |> Map.values()
    |> List.flatten()
  end

  def app_to_root_modules do
    case :persistent_term.get(__MODULE__, :not_loaded) do
      :not_loaded ->
        init()

      term ->
        term
    end
  end

  defp register_mappings(app_to_root_modules) do
    :persistent_term.put(__MODULE__, app_to_root_modules)
    app_to_root_modules
  end

  defp root_modules_for_apps(deps_apps) do
    deps_apps
    |> Enum.map(fn app_name ->
      all_modules = app_modules(app_name)

      case Enum.filter(all_modules, fn module -> length(safe_split_module(module)) == 1 end) do
        [] -> {app_name, [Expert]}
        root_modules -> {app_name, root_modules}
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp app_modules(dep_app) do
    Application.ensure_loaded(dep_app)

    case :application.get_key(dep_app, :modules) do
      {:ok, modules} ->
        modules

      _ ->
        [Expert]
    end
  end

  defp safe_split_module(module) do
    case Ast.Module.safe_split(module) do
      {:elixir, segments} -> segments
      {:erlang, _} -> []
    end
  end

  defp extra_apps do
    Map.new(@extra_apps, fn {k, v} ->
      root_module =
        v
        |> List.wrap()
        |> Module.concat()

      {String.to_atom(k), [root_module]}
    end)
  end

  defp init do
    discover_deps_apps()
    |> Enum.concat(@no_app_deps)
    |> then(&(&1 -- @dev_deps))
    |> root_modules_for_apps()
    |> Map.merge(extra_apps())
    |> register_mappings()
  end

  defp discover_deps_apps do
    cwd = File.cwd!()

    :application.loaded_applications()
    |> Enum.flat_map(fn {app_name, _description, _version} ->
      try do
        app_dir = Application.app_dir(app_name)

        if String.starts_with?(app_dir, cwd) do
          [app_name]
        else
          []
        end
      rescue
        _ -> []
      end
    end)
    |> Enum.sort()
  end
end
