defmodule Forge.Test.DiagnosticSupport do
  def execute_if(feature_condition) do
    matched? =
      Enum.all?(feature_condition, fn {feature_fn, value} ->
        apply(Features, feature_fn, []) == value
      end)

    if matched? do
      :ok
    else
      :skip
    end
  end
end
