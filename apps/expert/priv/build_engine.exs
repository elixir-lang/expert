{:ok, _} = Application.ensure_all_started(:elixir)
{:ok, _} = Application.ensure_all_started(:mix)

{args, _, _} =
  OptionParser.parse(
    System.argv(),
    strict: [
      vsn: :string,
      source_path: :string
    ]
  )

expert_vsn = Keyword.fetch!(args, :vsn)
engine_source_path = Keyword.fetch!(args, :source_path)

expert_data_path = :filename.basedir(:user_data, "Expert", %{version: expert_vsn})

System.put_env("MIX_INSTALL_DIR", expert_data_path)

dbg(expert_data_path)

Mix.Task.run("local.hex", ["--force"])
Mix.Task.run("local.rebar", ["--force"])

Mix.install([{:engine, path: engine_source_path, env: :dev}],
  start_applications: false,
  config_path: Path.join(engine_source_path, "config/config.exs"),
  lockfile: Path.join(engine_source_path, "mix.lock")
)

install_path = Mix.install_project_dir()

dbg(install_path)

dev_build_path = Path.join([install_path, "_build", "dev"])
ns_build_path = Path.join([install_path, "_build", "dev_ns"])

File.rm_rf!(ns_build_path)
File.cp_r!(dev_build_path, ns_build_path)

Mix.Task.run("namespace", [
  "--directory",
  ns_build_path,
  "--cwd",
  install_path,
  "--include-app",
  "engine",
  "--include-root",
  "Engine",
  "--include-root",
  "Future",
  "--dot-apps"
])

IO.puts("engine_path:" <> ns_build_path)
