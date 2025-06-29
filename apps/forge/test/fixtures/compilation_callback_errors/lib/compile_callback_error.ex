defmodule CompileCallbackError do
  @after_verify __MODULE__
  def __after_verify__(_) do
    raise "boom"
  end
end
