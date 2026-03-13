defmodule Forge.Ast.Detection.AliasTest do
  use Forge.Test.DetectionCase,
    for: Forge.Ast.Detection.Alias,
    assertions: [[:alias, :*]]
end
