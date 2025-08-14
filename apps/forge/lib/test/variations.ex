defmodule Forge.Test.Variations do
  def wrap_with(:nothing, text) do
    text
  end

  def wrap_with(:match, text) do
    """
    x = #{text}
    """
  end

  def wrap_with(:module, text) do
    """
    defmodule MyModule do
      #{text}
    end
    """
  end

  def wrap_with(:function_body, text) do
    body = """
    def func do
      #{text}
    end
    """

    wrap_with(:module, body)
  end

  def wrap_with(:function_arguments, text) do
    args = """
     def func(#{text}) do
     end
    """

    wrap_with(:module, args)
  end

  def wrap_with(:comprehension_generator, text) do
    """
    for x <- #{text} do
    x
    end
    """
  end

  def wrap_with(:function_call, text) do
    "Enum.map(things, #{text})"
  end
end
