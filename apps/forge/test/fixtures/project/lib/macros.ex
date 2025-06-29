defmodule Project.Macros do
  defmacro macro_add(a, b) do
    quote do
      unquote(a) + unquote(b)
    end
  end

  defmacro l(message) do
    quote do
      require Logger
      Logger.info("message is: #{unquote(inspect(message))}")
    end
  end

  defmacro macro_1_without_parens(arg) do
    arg
  end

  defmacro macro_2_without_parens(arg1, arg2, arg3, arg4) do
    [arg1, arg2, arg3, arg4]
  end
end
