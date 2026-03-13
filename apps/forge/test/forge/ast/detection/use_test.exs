defmodule Forge.Ast.Detection.UseTest do
  use Forge.Test.DetectionCase,
    for: Forge.Ast.Detection.Use,
    assertions: [[:use, :*]]
end
