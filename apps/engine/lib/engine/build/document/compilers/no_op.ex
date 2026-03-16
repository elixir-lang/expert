defmodule Engine.Build.Document.Compilers.NoOp do
  @moduledoc """
  A no-op, catch-all compiler. Always enabled, recognizes everything and returns no errors
  """
  @behaviour Engine.Build.Document.Compiler

  def recognizes?(_), do: true

  def enabled?, do: true

  def compile(_), do: {:ok, []}
end
