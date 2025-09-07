Mix.install([:jason])

versions = [
  %{elixir: "1.18.4", otp: "27"},
  %{elixir: "1.18.4", otp: "26"},
  %{elixir: "1.17", otp: "27"},
  %{elixir: "1.17", otp: "26"},
  %{elixir: "1.17", otp: "25"},
  %{elixir: "1.16", otp: "26"},
  %{elixir: "1.16", otp: "25"},
  %{elixir: "1.15.8", otp: "26"},
  %{elixir: "1.15.8", otp: "25"}
]

%{
  include:
    for project <- ["engine", "expert_credo", "forge"], version <- versions do
      Map.put(version, :project, project)
    end ++ [%{elixir: "1.17.3", otp: "27.3.4.1", project: "expert"}]
}
|> Jason.encode!(pretty: true)
|> then(&File.write!(".github/matrix.json", &1))
