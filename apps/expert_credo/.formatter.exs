# Used by "mix format"
Code.require_file("../../.formatter-config.exs", __DIR__)

[
  plugins: [Quokka],
  quokka: Formatter.Config.quokka(),
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
