defmodule Forge.Ast.Detection.StructReferenceTest do
  use Forge.Test.DetectionCase,
    for: Forge.Ast.Detection.StructReference,
    assertions: [[:struct_reference, :*]],
    skip: [[:struct_fields, :*], [:struct_field_value, :*], [:struct_field_key, :*]],
    variations: [:match, :function_arguments]

  test "is detected if a module reference starts in function arguments" do
    assert_detected ~q[def my_function(%_«»)]
  end

  test "is detected if a module reference start in a t type spec" do
    assert_detected ~q[@type t :: %_«»]
  end

  test "is detected if the reference is for %__MOD in a function definition " do
    assert_detected ~q[def my_fn(%_«_MOD»]
  end

  test "is detected if the reference is on the right side of a match" do
    assert_detected ~q[foo = %U«se»]
  end

  test "is detected if the reference is on the left side of a match" do
    assert_detected ~q[ %U«se» = foo]
  end

  test "is detected if the reference is for %__} " do
    assert_detected ~q[%__]
  end

  test "is not detected if the reference is for %__MOC in a function definition" do
    refute_detected ~q[def my_fn(%__MOC)]
  end

  test "is detected if module reference starts with %" do
    assert_detected ~q[def something(my_thing, %S«truct»{})]
  end

  test "is not detected if a module reference lacks a %" do
    refute_detected ~q[def my_function(__)]
  end
end
