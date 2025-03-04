# Used by "mix format"
imported_deps =
  if Mix.env() == :test do
    [:patch, :common]
  else
    [:common]
  end

locals_without_parens = [with_progress: 3]

[
  locals_without_parens: locals_without_parens,
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
  # import_deps: imported_deps
]
