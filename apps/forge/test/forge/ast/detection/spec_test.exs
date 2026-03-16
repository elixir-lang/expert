defmodule Forge.Ast.Detection.SpecTest do
  use Forge.Test.DetectionCase,
    for: Forge.Ast.Detection.Spec,
    assertions: [[:spec, :*]]
end
