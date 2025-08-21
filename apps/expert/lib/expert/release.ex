defmodule Expert.Release do
  def assemble(release) do
    Mix.Task.run(:namespace, [release.path])

    engine_path = Path.expand("../../../engine", __DIR__)

    source = Path.join([engine_path, "_build/dev_ns"])

    dest =
      Path.join([
        release.path,
        "lib",
        "xp_expert-#{release.version}",
        "priv"
      ])

    File.cp_r!(source, dest)

    release
  end
end
