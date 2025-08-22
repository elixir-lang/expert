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

major = :otp_release |> :erlang.system_info() |> List.to_string()
version_file = Path.join([:code.root_dir(), "releases", major, "OTP_VERSION"])

erlang_vsn =
  try do
    {:ok, contents} = File.read(version_file)
    String.split(contents, "\n", trim: true)
  else
    [full] -> full
    _ -> major
  catch
    :error ->
      major
  end

elixir_vsn = System.version()

user_data_path = :filename.basedir(:user_data, "Expert", %{version: expert_vsn})
out_path = Path.join([user_data_path, "engine-#{elixir_vsn}-otp-#{erlang_vsn}"])
build_path = Path.join(out_path, "dev")

if not File.exists?(build_path) do
  System.put_env("MIX_INSTALL_DIR", out_path)

  Mix.Task.run("local.hex", ["--force"])
  Mix.Task.run("local.rebar", ["--force"])
  Mix.Project.in_project(:engine, engine_source_path, [build_path: out_path], fn _module ->
    Mix.Task.run("compile", [])
    Mix.Task.run("namespace", [build_path, "--cwd", out_path])
  end)
end

IO.puts("engine_path:" <> build_path)
