# Used by "mix format"
Code.require_file("../../.formatter.exs", __DIR__)

eventual_assertions = [
  assert_eventually: 1,
  assert_eventually: 2,
  refute_eventually: 1,
  refute_eventually: 2
]

detected_assertions = [
  assert_detected: 1,
  assert_detected: 2,
  refute_detected: 1,
  refute_detected: 2
]

assertions = eventual_assertions ++ detected_assertions

current_directory = Path.dirname(__ENV__.file)

impossible_to_format =
  [current_directory, "test", "fixtures", "**/*"]
  |> Path.join()
  |> Path.wildcard()

inputs =
  Enum.flat_map(
    [
      "{mix,.formatter}.exs",
      "{config,test}/**/*.{ex,exs}",
      "lib/forge/**/*.{ex,ex}",
      "lib/mix/**/*.{ex,exs}"
    ],
    fn path ->
      current_directory
      |> Path.join(path)
      |> Path.wildcard()
    end
  )

inputs = inputs -- impossible_to_format

[
  plugins: [Quokka],
  quokka: Formatter.Config.quokka(),
  inputs: inputs,
  locals_without_parens: assertions,
  export: [locals_without_parens: assertions]
]
