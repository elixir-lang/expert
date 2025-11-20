Mix.install([:jason])

versions = [
  %{elixir: "1.19", otp: "28", os: "ubuntu-latest"},
  %{elixir: "1.18.4", otp: "28", os: "ubuntu-latest"},
  %{elixir: "1.18", otp: "27", os: "ubuntu-latest"},
  %{elixir: "1.18", otp: "26", os: "ubuntu-latest"},
  %{elixir: "1.17", otp: "27", os: "ubuntu-latest"},
  %{elixir: "1.17", otp: "26", os: "ubuntu-latest"},
  %{elixir: "1.16", otp: "26", os: "ubuntu-latest"},
]

expert_matrix =
  [
    %{elixir: "1.17.3", otp: "27.3.4.1", project: "expert", os: "ubuntu-latest"},
    %{elixir: "1.17.3", otp: "27.3.4.1", project: "expert", os: "windows-2022"}
  ]

%{
  include:
    for project <- ["engine", "expert_credo", "forge"], version <- versions do
      Map.put(version, :project, project)
    end ++ expert_matrix
}
|> Jason.encode!(pretty: true)
|> then(&File.write!(".github/matrix.json", &1))
