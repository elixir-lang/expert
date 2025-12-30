defmodule Navigations.MyLiveView do
  use Phoenix.Component
  import MyComponents

  def render(assigns) do
    ~H"""
    <.button>Click me</.button>
    <.table rows={@rows}>
      <:col header="Name"><%= @row.name %></:col>
    </.table>
    <MyComponents.button>Click me too</MyComponents.button>
    """
  end

  def table(assigns) do
    ~H"""
    <table><%= for row <- @rows do %><tr><%= render_slot(@col, row) %></tr><% end %></table>
    """
  end
end
