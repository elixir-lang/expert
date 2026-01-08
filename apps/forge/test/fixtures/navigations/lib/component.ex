defmodule Component do
  defmacro __using__(_) do
    quote do
      import(unquote(__MODULE__))
    end
  end

  def sigil_H(_, _), do: nil
end
