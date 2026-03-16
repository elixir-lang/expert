defmodule Forge.Ast.Detection.StringTest do
  use Forge.Test.DetectionCase,
    for: Forge.Ast.Detection.String,
    assertions: [[:strings, :*]],
    skip: [
      [:doc, :*],
      [:keyword, :single_line],
      # we skip other tests that have strings in them
      [:keyword, :multi_line],
      [:module_doc, :*]
    ],
    variations: [
      :function_arguments,
      :function_body,
      :function_call,
      :match,
      :module
    ]

  test "is detected if a string is keyword values" do
    assert_detected ~q/def func(string: "v«alue»", atom: :value2, int: 6, float: 2.0, list: [1, 2], tuple: {3, 4}) do/
  end
end
