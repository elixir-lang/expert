defmodule SigilsWithoutLiveView.BasicModule do
  @moduledoc """
  A basic Elixir module without any Phoenix dependencies.
  This module demonstrates standard Elixir code that should work
  regardless of whether Phoenix/LiveView is available.
  """

  @type result :: String.t()

  defstruct [:name, :value]

  @doc """
  A simple greeting function.
  """
  @spec greet(String.t()) :: result
  def greet(name) do
    "Hello, #{name}!"
  end

  @doc """
  Returns a list of items.
  """
  def list_items do
    [:item1, :item2, :item3]
  end

  @doc """
  Processes a struct.
  """
  def process(%__MODULE__{name: name, value: value}) do
    {name, value}
  end
end
