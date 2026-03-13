defmodule Forge.Ast.Detection.RequireTest do
  use Forge.Test.DetectionCase,
    for: Forge.Ast.Detection.Require,
    assertions: [[:require, :*]]

end
