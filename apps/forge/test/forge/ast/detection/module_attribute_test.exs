defmodule Forge.Ast.Detection.ModuleAttributeTest do
  use Forge.Test.DetectionCase,
    for: Forge.Ast.Detection.ModuleAttribute,
    assertions: [
      [:module_attribute, :*],
      [:callbacks, :*]
    ],
    skip: [
      [:doc, :*],
      [:module_doc, :*],
      [:spec, :*],
      [:type, :*]
    ],
    variations: [:module]
end
