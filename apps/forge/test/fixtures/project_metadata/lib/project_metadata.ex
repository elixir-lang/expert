defmodule ProjectMetadata do
  def zero_arity do
  end

  def one_arity(first) do
    first
  end

  def two_arity(first, second) do
    {first, second}
  end
end
