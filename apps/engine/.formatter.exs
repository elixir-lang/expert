# Used by "mix format"
current_directory = Path.dirname(__ENV__.file)

import_deps = [:forge]

locals_without_parens = [defkey: 2, defkey: 3, with_wal: 2]

[
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens],
  import_deps: import_deps,
  inputs: ["*.exs", "{lib,test}/**/*.{ex,exs}"]
]
