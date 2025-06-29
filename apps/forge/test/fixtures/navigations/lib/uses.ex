defmodule Navigations.Uses do
  alias MyDefinition

  def my_function do
    MyDefinition.greet("world")
  end

  def other_function do
    IO.puts("hi")
  end
end
