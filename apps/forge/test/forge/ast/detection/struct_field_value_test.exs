defmodule Forge.Ast.Detection.StructFieldValueTest do
  use Forge.Test.DetectionCase,
    for: Forge.Ast.Detection.StructFieldValue,
    assertions: [[:struct_field_value, :*]],
    skip: [
      [:struct_fields, :*],
      [:struct_reference, :*],
      [:struct_field_key, :*]
    ],
    variations: [:module]

  test "is detected directly after the colon" do
    assert_detected ~q[%User{foo: «»}]
  end

  test "is not detected if the cursor is a multiple line definition in a key position" do
    assert_detected ~q[
      %User{
        foo: «1,»
      }
    ]
  end
end
