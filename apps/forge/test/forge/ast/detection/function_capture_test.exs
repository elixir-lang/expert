defmodule Forge.Ast.Detection.FunctionCaptureTest do
  use Forge.Test.DetectionCase,
    for: Forge.Ast.Detection.FunctionCapture,
    assertions: [[:function_capture, :*]],
    variations: [:match, :function_body]

  test "detected if the capture is inside an unformatted function call" do
    assert_detected ~q[list = Enum.map(1..10,&«Enum»)]
  end

  test "detected if the capture is inside a function call after the dot" do
    assert_detected ~q[list = Enum.map(1..10, &«Enum.f»)]
  end

  test "detected if the capture is in the body of a for" do
    assert_detected ~q[for x <- Enum.map(1..10, &«String.»)]
  end

  test "is not detected if the capture is inside an unformatted function call" do
    refute_detected ~q[list = Enum.map(1..10,Enum)]
  end

  test "is not detected if the capture is inside a function call after the dot" do
    refute_detected ~q[list = Enum.map(1..10, Enum.f)]
  end

  test "is not detected if the capture is in the body of a for" do
    refute_detected ~q[for x <- Enum.map(1..10, String.)]
  end
end
