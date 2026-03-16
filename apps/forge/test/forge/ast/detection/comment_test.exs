defmodule Forge.Ast.Detection.CommentTest do
  use Forge.Test.DetectionCase,
    for: Forge.Ast.Detection.Comment,
    assertions: [[:comment, :*]]
end
