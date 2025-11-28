defmodule Expert.Release do
  def assemble(release) do
    Mix.Task.run(:namespace, [release.path])

    expert_root = Path.expand("../../../..", __DIR__)
    engine_path = Path.join([expert_root, "apps", "engine"])
    forge_path = Path.join([expert_root, "apps", "forge"])

    engine_sources =
      [
        "lib",
        "deps",
        "mix.exs",
        "config",
        "mix.lock"
      ]
      |> Enum.map(&Path.join([engine_path, &1]))

    forge_sources =
      [
        "lib",
        "src",
        "mix.exs",
        "config",
        "mix.lock"
      ]
      |> Enum.map(&Path.join([forge_path, &1]))

    root_exs = Path.join([expert_root, "*.exs"])
    version_file = Path.join([expert_root, "version.txt"])

    dest =
      Path.join([
        release.path,
        "lib",
        "xp_expert-#{release.version}",
        "priv",
        "engine_source"
      ])

    for source <- engine_sources do
      dest_path = Path.join([dest, "apps", "engine", Path.basename(source)])
      File.mkdir_p!(Path.dirname(dest_path))
      File.cp_r!(source, dest_path)
    end

    for source <- forge_sources do
      dest_path = Path.join([dest, "apps", "forge", Path.basename(source)])
      File.mkdir_p!(Path.dirname(dest_path))
      File.cp_r!(source, dest_path)
    end

    for exs_file <- Path.wildcard(root_exs) do
      dest_path = Path.join([dest, Path.basename(exs_file)])
      File.cp_r!(exs_file, dest_path)
    end

    File.cp!(version_file, Path.join([dest, "version.txt"]))

    release
  end
end
