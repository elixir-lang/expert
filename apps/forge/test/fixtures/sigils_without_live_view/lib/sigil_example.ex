defmodule SigilsWithoutLiveView.SigilExample do
  @moduledoc """
  Demonstrates that the HeexNormalizer only activates when `use Phoenix.Component`
  (or LiveView/LiveComponent) is present. This module defines a custom ~H sigil,
  but jump-to-definition for `<.button>` will NOT work because Phoenix.Component
  is not used.
  """

  defmacrop sigil_H({:<<>>, _meta, [string]}, _modifiers) when is_binary(string) do
    string
  end

  defmacrop sigil_H({:<<>>, _meta, _parts} = ast, _modifiers) do
    quote do: unquote(ast)
  end

  def button(assigns) do
    "<button class='custom'>#{assigns[:label]}</button>"
  end

  def render(assigns) do
    ~H"""
    <div class="container">
      <.button label="Click me"></.button>
    </div>
    """
  end
end
