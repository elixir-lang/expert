defmodule Forge.Ast.Detection.PipeTest do
  use Forge.Test.DetectionCase,
    for: Forge.Ast.Detection.Pipe,
    assertions: [[:pipe, :*]],
    variations: [:function_arguments],
    skip: [[:module_attribute, :multi_line_pipe]]

  test "is false if there is no pipe in the string" do
    refute_detected ~q[Enum.foo]
  end
end
