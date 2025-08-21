alias Forge.Project

other_project =
  [
    File.cwd!(),
    "..",
    "..",
    "..",
    "eakins"
  ]
  |> Path.join()
  |> Path.expand()

project = Forge.Project.new("file://#{other_project}")
