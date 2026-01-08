# Used by "mix format"
imported_deps =
  if Mix.env() == :test do
    [:patch, :forge]
  else
    [:forge]
  end

[
  locals_without_parens: [],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  import_deps: imported_deps
]
