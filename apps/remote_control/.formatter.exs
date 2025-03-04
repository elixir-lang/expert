# Used by "mix format"
current_directory = Path.dirname(__ENV__.file)

import_deps = [:common]

impossible_to_format = [
  Path.join([
    current_directory,
    "test",
    "fixtures",
    "compilation_errors",
    "lib",
    "compilation_errors.ex"
  ]),
  Path.join([current_directory, "test", "fixtures", "parse_errors", "lib", "parse_errors.ex"])
]

locals_without_parens = [with_progress: 2, with_progress: 3, defkey: 2, defkey: 3, with_wal: 2]

[
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens],
  # import_deps: import_deps,
  inputs:
    Enum.flat_map(
      [
        Path.join(current_directory, "*.exs"),
        Path.join(current_directory, "{lib,test}/**/*.{ex,exs}")
      ],
      &Path.wildcard(&1, match_dot: true)
    ) -- impossible_to_format
]
