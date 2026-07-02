Mix.install([:jason])

versions = [
  %{elixir: "1.20", otp: "29", os: "ubuntu-latest"},
  %{elixir: "1.19", otp: "28", os: "ubuntu-latest"},
  %{elixir: "1.18.4", otp: "28", os: "ubuntu-latest"},
  %{elixir: "1.18", otp: "27", os: "ubuntu-latest"},
  %{elixir: "1.18", otp: "26", os: "ubuntu-latest"},
  %{elixir: "1.17", otp: "27", os: "ubuntu-latest"},
  %{elixir: "1.17", otp: "26", os: "ubuntu-latest"},
  %{elixir: "1.16", otp: "26", os: "ubuntu-latest"}
]

expert_matrix =
  [
    %{elixir: "1.20.0", otp: "29.0.1", project: "expert", os: "ubuntu-latest"},
    %{elixir: "1.20.0", otp: "29.0.1", project: "expert", os: "windows-2022"}
    | for version <- tl(versions) do
        Map.put(version, :project, "expert")
      end
  ]

engine_matrix =
  for version <- versions do
    Map.put(version, :project, "engine")
  end ++
    [
      %{elixir: "1.20.0", otp: "29.0.1", project: "engine", os: "windows-2022"}
    ]

other_project_matrix =
  for project <- ["expert_credo", "forge"], version <- versions do
    Map.put(version, :project, project)
  end

%{
  include: engine_matrix ++ other_project_matrix ++ expert_matrix
}
|> Jason.encode!(pretty: true)
|> then(&File.write!(".github/matrix.json", &1))
