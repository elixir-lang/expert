# Used by "mix format"
Code.require_file("../../.formatter.exs", __DIR__)

imported_deps =
  if Mix.env() == :test do
    [:patch, :forge]
  else
    [:forge]
  end

[
  plugins: [Quokka],
  quokka: Formatter.Config.quokka(),
  locals_without_parens: [],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  import_deps: imported_deps
]
