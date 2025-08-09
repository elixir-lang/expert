defmodule Expert.Release do
  def assemble(release) do
    engine_path = Path.expand("../../../engine", __DIR__)

    source = Path.join([engine_path, "_build/dev_ns"])

    dest =
      Path.join([
        release.path,
        "lib",
        "#{release.name}-#{release.version}",
        "priv",
        "engine"
      ])

    File.mkdir_p!(dest)

    File.cp_r!(source, dest)

    release
  end
end
