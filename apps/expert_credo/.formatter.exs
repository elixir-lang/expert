# Used by "mix format"
Code.require_file("../../.formatter.exs", __DIR__)

[
  plugins: [Quokka],
  quokka: Formatter.Config.quokka(),
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
