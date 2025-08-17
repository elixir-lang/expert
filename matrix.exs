Mix.install([:jason])

projects = [
  "engine",
  "expert",
  "expert_credo",
  "forge"
]

# renable these once we make the repo public
versions = [
  # %{elixir: "1.18.1", otp: "27"},
  # %{elixir: "1.18.1", otp: "26"},
  # %{elixir: "1.17", otp: "27"},
  # %{elixir: "1.17", otp: "26"},
  # %{elixir: "1.17", otp: "25"},
  # %{elixir: "1.16", otp: "26"},
  # %{elixir: "1.16", otp: "25"},
  # %{elixir: "1.15.8", otp: "26"},
  %{elixir: "1.15.8", otp: "25"}
]

%{
  include:
    for project <- projects, version <- versions do
      Map.put(version, :project, project)
    end
}
|> Jason.encode!(pretty: true)
|> then(&File.write!(".github/matrix.json", &1))
